# Run with:  .\test.ps1
# Or specific scenarios:  .\test.ps1 -Only crud,failover
[CmdletBinding()]
param(
    [string[]]$Only = @('crud','validation','lb-gateway','lb-worker','failover-gateway','failover-worker','persistence','dlq','scale','security'),
    [string]$Base  = 'http://localhost:8080/api/products',
    [string]$MgmtUrl = 'http://localhost:15672'
)

$ErrorActionPreference = 'Stop'
# When invoked via `powershell -File`, array args arrive as a single string. Split here.
$Only = $Only | ForEach-Object { $_ -split ',' } | Where-Object { $_ } | ForEach-Object { $_.Trim() }
$script:pass = 0
$script:fail = 0

function Step($name) { Write-Host "`n=== $name ===" -ForegroundColor Cyan }
function Ok($msg)    { Write-Host "  [OK]   $msg" -ForegroundColor Green; $script:pass++ }
function Bad($msg)   { Write-Host "  [FAIL] $msg" -ForegroundColor Red;   $script:fail++ }
function Info($msg)  { Write-Host "  $msg" -ForegroundColor DarkGray }
function Run($tag)   { return $Only -contains $tag }
function New-Cred([string]$u,[string]$p) {
    [pscredential]::new($u, (ConvertTo-SecureString $p -AsPlainText -Force))
}

function Wait-Api {
    for ($i = 0; $i -lt 30; $i++) {
        try { Invoke-RestMethod $Base -TimeoutSec 2 | Out-Null; return } catch { Start-Sleep -Seconds 1 }
    }
    throw "API not reachable at $Base"
}

Step 'Preflight'
try { Wait-Api; Ok "API reachable at $Base" } catch { Bad $_.Exception.Message; exit 1 }

#-- 1. CRUD ---------------------------------------------------------------
if (Run 'crud') {
    Step 'CRUD'
    try {
        $created = Invoke-RestMethod -Method Post -Uri $Base -ContentType 'application/json' `
            -Body (@{name='Smoke';description='auto';price=1.5;stock=3} | ConvertTo-Json)
        if (-not $created.id) { throw 'no id returned' }
        Ok "CREATE id=$($created.id)"

        $got = Invoke-RestMethod "$Base/$($created.id)"
        if ($got.name -ne 'Smoke') { throw "GET name=$($got.name)" } else { Ok 'GET' }

        $list = Invoke-RestMethod $Base
        if ($list.Count -lt 1) { throw 'LIST empty' } else { Ok "LIST ($($list.Count) rows)" }

        Invoke-RestMethod -Method Put -Uri "$Base/$($created.id)" -ContentType 'application/json' `
            -Body (@{name='Smoke2';description='auto';price=2;stock=4} | ConvertTo-Json) | Out-Null
        $upd = Invoke-RestMethod "$Base/$($created.id)"
        if ($upd.name -ne 'Smoke2') { throw "UPDATE name=$($upd.name)" } else { Ok 'UPDATE' }

        Invoke-RestMethod -Method Delete -Uri "$Base/$($created.id)" | Out-Null
        $after = Invoke-RestMethod "$Base/$($created.id)"
        if ($after.error -ne 'not found') { Bad "DELETE did not remove (got $($after | ConvertTo-Json -Compress))" }
        else { Ok 'DELETE' }
    } catch { Bad $_.Exception.Message }
}

#-- 2. Validation ---------------------------------------------------------
if (Run 'validation') {
    Step 'Validation (bad payload should 400)'
    try {
        Invoke-RestMethod -Method Post -Uri $Base -ContentType 'application/json' -Body '{"price":1,"stock":1}' | Out-Null
        Bad 'expected 400 but request succeeded'
    } catch {
        if ($_.Exception.Response.StatusCode.value__ -eq 400) { Ok 'rejected with 400' }
        else { Bad "unexpected status $($_.Exception.Response.StatusCode)" }
    }
}

#-- 3. Gateway load balancing --------------------------------------------
if (Run 'lb-gateway') {
    Step 'Gateway load balancing'
    1..20 | ForEach-Object { Invoke-RestMethod $Base | Out-Null }
    $logs = docker compose logs --tail=400 gateway 2>&1
    $g1 = ($logs | Select-String 'gateway-1').Count
    $g2 = ($logs | Select-String 'gateway-2').Count
    Info "gateway-1 log lines: $g1   gateway-2 log lines: $g2"
    if ($g1 -gt 0 -and $g2 -gt 0) { Ok 'both gateways served traffic' }
    else { Bad 'only one gateway appears in logs' }
}

#-- 4. Worker load balancing ---------------------------------------------
if (Run 'lb-worker') {
    Step 'Worker load balancing'
    1..20 | ForEach-Object { Invoke-RestMethod $Base | Out-Null }
    Start-Sleep -Seconds 1
    $logs = docker compose logs --tail=600 worker 2>&1
    $w1 = ($logs | Select-String 'worker-1.*Received op=').Count
    $w2 = ($logs | Select-String 'worker-2.*Received op=').Count
    Info "worker-1 handled: $w1   worker-2 handled: $w2"
    if ($w1 -gt 0 -and $w2 -gt 0) { Ok 'both workers consumed messages' }
    else { Bad 'only one worker appears to consume' }
}

#-- 5. Gateway failover --------------------------------------------------
if (Run 'failover-gateway') {
    Step 'Gateway failover (kill gateway-1)'
    try {
        docker kill wsmt-gateway-1 | Out-Null
        $okCount = 0
        1..10 | ForEach-Object {
            try { Invoke-RestMethod $Base | Out-Null; $okCount++ } catch {}
        }
        Info "$okCount/10 requests succeeded while gateway-1 was down"
        if ($okCount -ge 9) { Ok 'traffic continued via gateway-2' } else { Bad 'too many failures' }
    } finally {
        docker start wsmt-gateway-1 | Out-Null
    }
}

#-- 6. Worker failover ---------------------------------------------------
if (Run 'failover-worker') {
    Step 'Worker failover (kill worker-1)'
    try {
        docker kill wsmt-worker-1 | Out-Null
        $okCount = 0
        1..10 | ForEach-Object {
            try {
                Invoke-RestMethod -Method Post -Uri $Base -ContentType 'application/json' `
                    -Body (@{name="failover$_";price=1;stock=1} | ConvertTo-Json) | Out-Null
                $okCount++
            } catch {}
        }
        Info "$okCount/10 CRUD ops succeeded while worker-1 was down"
        if ($okCount -ge 9) { Ok 'worker-2 absorbed the load' } else { Bad 'requests failed' }
    } finally {
        docker start wsmt-worker-1 | Out-Null
    }
}

#-- 7. Message persistence (broker restart) ------------------------------
if (Run 'persistence') {
    Step 'Message persistence (stop workers, restart RabbitMQ)'
    try {
        docker compose stop worker | Out-Null
        $jobs = 1..3 | ForEach-Object {
            Start-Job -ScriptBlock {
                param($u, $n)
                try {
                    Invoke-RestMethod -Method Post -Uri $u -ContentType 'application/json' `
                        -Body (@{name="persist-$n";price=1;stock=1} | ConvertTo-Json) -TimeoutSec 20
                } catch {}
            } -ArgumentList $Base, $_
        }
        Start-Sleep -Seconds 2
        Info 'restarting rabbitmq...'
        docker compose restart rabbitmq | Out-Null
        # wait for healthy
        for ($i=0; $i -lt 30; $i++) {
            $h = docker inspect --format '{{.State.Health.Status}}' wsmt-rabbitmq-1 2>$null
            if ($h -eq 'healthy') { break }
            Start-Sleep -Seconds 1
        }
        docker compose start worker | Out-Null
        $jobs | Wait-Job -Timeout 30 | Out-Null
        $jobs | Remove-Job -Force
        Start-Sleep -Seconds 2
        $all = Invoke-RestMethod $Base
        $survived = ($all | Where-Object { $_.name -like 'persist-*' }).Count
        Info "rows named persist-* after restart: $survived"
        if ($survived -ge 1) { Ok 'messages survived broker restart' } else { Bad 'no persisted messages found' }
    } catch { Bad $_.Exception.Message }
}

#-- 8. Dead-letter queue -------------------------------------------------
if (Run 'dlq') {
    Step 'Dead-letter queue (publish poison message)'
    $cred = New-Cred 'wsmt' 'wsmt'
    try {
        # Read current DLQ depth
        $before = (Invoke-RestMethod -Uri "$MgmtUrl/api/queues/%2F/products.dead" -Credential $cred).messages
        Info "DLQ depth before: $before"

        # Publish a non-JSON payload directly to the products exchange. The worker's
        # Jackson converter will fail and (since there is no reply_to) the message
        # will be rejected with requeue=false and dead-lettered.
        $body = @{
            properties       = @{ delivery_mode = 2; content_type = 'application/json' }
            routing_key      = 'products'
            payload          = 'this-is-not-json'
            payload_encoding = 'string'
        } | ConvertTo-Json
        Invoke-RestMethod -Method Post -Uri "$MgmtUrl/api/exchanges/%2F/products.exchange/publish" `
            -Credential $cred -ContentType 'application/json' -Body $body | Out-Null

        # Wait for the message to be routed through retry -> DLX
        $after = $before
        for ($i = 0; $i -lt 20; $i++) {
            Start-Sleep -Seconds 1
            $after = (Invoke-RestMethod -Uri "$MgmtUrl/api/queues/%2F/products.dead" -Credential $cred).messages
            if ($after -gt $before) { break }
        }
        Info "DLQ depth after:  $after"
        if ($after -gt $before) { Ok 'poison message routed to DLQ' } else { Bad 'DLQ did not grow' }
    } catch { Bad $_.Exception.Message }
}

#-- 9. Horizontal scaling ------------------------------------------------
if (Run 'scale') {
    Step 'Horizontal scale (workers -> 4)'
    try {
        docker compose up -d --scale worker=4 --scale gateway=2 | Out-Null
        $cred = New-Cred 'wsmt' 'wsmt'
        $consumers = 0
        for ($i = 0; $i -lt 60; $i++) {
            Start-Sleep -Seconds 1
            try {
                $q = Invoke-RestMethod -Uri "$MgmtUrl/api/queues/%2F/products.commands" -Credential $cred
                $consumers = [int]$q.consumers
                if ($consumers -ge 4) { break }
            } catch {}
        }
        Info "consumers on products.commands = $consumers (waited ${i}s)"
        if ($consumers -ge 4) { Ok '4 consumers attached' } else { Bad "expected >=4, got $consumers" }
    } catch { Bad $_.Exception.Message } finally {
        docker compose up -d --scale worker=2 --scale gateway=2 | Out-Null
    }
}

#-- 10. Security ----------------------------------------------------------
if (Run 'security') {
    Step 'Security (wrong RabbitMQ creds should be rejected)'
    $cred = New-Cred 'bad' 'bad'
    try {
        Invoke-RestMethod -Uri "$MgmtUrl/api/overview" -Credential $cred | Out-Null
        Bad 'bad credentials accepted (!)'
    } catch {
        if ($_.Exception.Response.StatusCode.value__ -eq 401) { Ok 'broker rejected bad credentials (401)' }
        else { Bad "unexpected: $($_.Exception.Message)" }
    }
}

Write-Host ""
Write-Host "================ Summary ================" -ForegroundColor Yellow
Write-Host ("  Passed: {0}" -f $script:pass) -ForegroundColor Green
Write-Host ("  Failed: {0}" -f $script:fail) -ForegroundColor ($(if ($script:fail) {'Red'} else {'Green'}))
exit ($(if ($script:fail) { 1 } else { 0 }))
