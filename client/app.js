const API = '/api/products';
const form = document.getElementById('product-form');
const rows = document.getElementById('rows');
const statusEl = document.getElementById('status');
const submitBtn = document.getElementById('submit-btn');
const formTitle = document.getElementById('form-title');

function setStatus(msg, kind) {
  statusEl.textContent = msg || '';
  statusEl.className = 'status' + (kind ? ' ' + kind : '');
}

async function load() {
  setStatus('Loading…');
  try {
    const res = await fetch(API);
    if (!res.ok) throw new Error('HTTP ' + res.status);
    const list = await res.json();
    rows.innerHTML = list.map(p => `
      <tr>
        <td>${p.id}</td>
        <td>${escape(p.name)}</td>
        <td>${escape(p.description ?? '')}</td>
        <td>${p.price}</td>
        <td>${p.stock}</td>
        <td class="actions">
          <button data-edit="${p.id}">Edit</button>
          <button class="del" data-del="${p.id}">Delete</button>
        </td>
      </tr>`).join('');
    setStatus(`${list.length} item(s)`, 'ok');
  } catch (e) {
    setStatus('Failed to load: ' + e.message, 'error');
  }
}

function escape(s) {
  return String(s).replace(/[&<>"']/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
}

function resetForm() {
  form.reset();
  document.getElementById('id').value = '';
  submitBtn.textContent = 'Create';
  formTitle.textContent = 'Create product';
}

form.addEventListener('submit', async (e) => {
  e.preventDefault();
  const id = document.getElementById('id').value;
  const body = {
    name: document.getElementById('name').value,
    description: document.getElementById('description').value,
    price: parseFloat(document.getElementById('price').value),
    stock: parseInt(document.getElementById('stock').value, 10),
  };
  setStatus('Sending…');
  try {
    const res = await fetch(id ? `${API}/${id}` : API, {
      method: id ? 'PUT' : 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(body),
    });
    if (!res.ok) throw new Error('HTTP ' + res.status);
    resetForm();
    setStatus('Saved', 'ok');
    load();
  } catch (e) {
    setStatus('Save failed: ' + e.message, 'error');
  }
});

document.getElementById('reset-btn').addEventListener('click', resetForm);
document.getElementById('refresh-btn').addEventListener('click', load);

rows.addEventListener('click', async (e) => {
  const editId = e.target.getAttribute('data-edit');
  const delId = e.target.getAttribute('data-del');
  if (editId) {
    const res = await fetch(`${API}/${editId}`);
    if (res.ok) {
      const p = await res.json();
      document.getElementById('id').value = p.id;
      document.getElementById('name').value = p.name;
      document.getElementById('description').value = p.description ?? '';
      document.getElementById('price').value = p.price;
      document.getElementById('stock').value = p.stock;
      submitBtn.textContent = 'Update';
      formTitle.textContent = 'Edit product #' + p.id;
    }
  } else if (delId) {
    if (!confirm('Delete product ' + delId + '?')) return;
    const res = await fetch(`${API}/${delId}`, { method: 'DELETE' });
    if (res.ok) { setStatus('Deleted', 'ok'); load(); }
    else setStatus('Delete failed', 'error');
  }
});

load();
