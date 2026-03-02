// ── DOM References ──
const repoPathInput = document.getElementById('repo-path');
const logText = document.getElementById('log-text');

// ── State ──
let fleetState = [];
let selectedEndpointIndex = -1;
let pendingDeleteIndex = -1;
let pendingActionCallback = null;

// ── Helpers ──
async function apiCall(endpoint, method = 'GET', body = null) {
    try {
        const opts = { method, headers: { 'Content-Type': 'application/json' } };
        if (body) opts.body = JSON.stringify(body);
        const resp = await fetch('/api' + endpoint, opts);
        return await resp.json();
    } catch (err) {
        return { success: false, message: err.message };
    }
}

function showToast(msg, isError = false) {
    const toast = document.getElementById('toast');
    const tmsg = document.getElementById('toast-msg');
    tmsg.textContent = msg;
    toast.classList.toggle('error', isError);
    toast.classList.remove('hidden');
    toast.classList.add('show');
    setTimeout(() => { toast.classList.remove('show'); setTimeout(() => toast.classList.add('hidden'), 400); }, 3500);
}

function showLoading(text = 'Processing...') {
    document.getElementById('loading-text').textContent = text;
    document.getElementById('loading-overlay').classList.remove('hidden');
}
function hideLoading() { document.getElementById('loading-overlay').classList.add('hidden'); }

async function saveInventory() {
    await apiCall('/inventory', 'POST', fleetState);
}

// ── Tab Navigation ──
document.querySelectorAll('.nav-btn').forEach(btn => {
    btn.addEventListener('click', () => {
        document.querySelectorAll('.nav-btn').forEach(b => b.classList.remove('active'));
        btn.classList.add('active');
        document.querySelectorAll('.tab-pane').forEach(p => p.classList.remove('active'));
        const tab = document.getElementById('tab-' + btn.dataset.tab);
        if (tab) tab.classList.add('active');
        if (btn.dataset.tab === 'dashboard') updateDashboard();
        if (btn.dataset.tab === 'tasks') loadTasks();
        if (btn.dataset.tab === 'logs') fetchLogs();
        // Stop task polling when leaving tasks tab
        if (btn.dataset.tab !== 'tasks' && tasksInterval) {
            clearInterval(tasksInterval);
            tasksInterval = null;
        }
    });
});

// ── Init ──
async function initApp() {
    // Load path
    const res = await apiCall('/path', 'GET');
    if (res && res.path) repoPathInput.value = res.path;

    // Load inventory — handle both array and wrapped formats
    try {
        const invRes = await apiCall('/inventory', 'GET');
        console.log('Inventory response:', JSON.stringify(invRes));
        if (invRes) {
            if (Array.isArray(invRes)) {
                fleetState = invRes;
            } else if (invRes.inventory && Array.isArray(invRes.inventory)) {
                fleetState = invRes.inventory;
            }
        }
    } catch (e) {
        console.error('Failed to load inventory:', e);
    }
    renderFleetTable();
    updateDashboard();

    // Start smart polling (only polls active tab)
    setInterval(() => {
        const activeTab = document.querySelector('.nav-btn.active')?.dataset.tab;
        if (activeTab === 'logs') fetchLogs();
    }, 5000);
}

// ── Dashboard ──
function updateDashboard() {
    const total = fleetState.length;
    const online = fleetState.filter(e => e.status === 'Online').length;
    const outdated = fleetState.filter(e => e.applicable && e.applicable.length > 0).length;
    const compliant = fleetState.filter(e => e.status === 'Online' && (!e.applicable || e.applicable.length === 0)).length;

    document.getElementById('stat-total').textContent = total;
    document.getElementById('stat-online').textContent = online;
    document.getElementById('stat-outdated').textContent = outdated;
    document.getElementById('stat-compliant').textContent = compliant;

    // Donut chart
    const pct = total > 0 ? Math.round((compliant / total) * 100) : 0;
    const circumference = 2 * Math.PI * 52; // r=52
    const offset = circumference - (pct / 100) * circumference;
    const ring = document.getElementById('compliance-ring');
    ring.style.strokeDashoffset = offset;
    ring.style.stroke = pct >= 80 ? 'var(--success)' : pct >= 50 ? 'var(--warning)' : 'var(--danger)';
    document.getElementById('compliance-pct').textContent = pct + '%';

    // Fleet summary list
    const list = document.getElementById('fleet-summary-list');
    if (fleetState.length === 0) {
        list.innerHTML = '<p class="text-muted text-sm">No endpoints tracked yet.</p>';
    } else {
        list.innerHTML = fleetState.map(e => {
            const updCount = e.applicable ? e.applicable.length : 0;
            let updBadge;
            if (e.status === 'Not Applicable') updBadge = '<span class="badge badge-na">N/A</span>';
            else if (updCount > 0) updBadge = `<span class="badge badge-warning">${updCount} updates</span>`;
            else updBadge = '<span class="badge badge-success">Up to date</span>';
            const dotClass = e.status === 'Online' ? 'online' : e.status === 'Not Applicable' ? 'na' : 'offline';
            return `<div class="summary-row">
                <span class="host-name"><span class="status-dot ${dotClass}"></span> ${e.hostname}</span>
                ${updBadge}
            </div>`;
        }).join('');
    }
}

// ── Fleet Table ──
function renderFleetTable() {
    const tbody = document.getElementById('fleet-table-body');
    const emptyState = document.getElementById('fleet-empty-state');
    const bulkActions = document.getElementById('fleet-bulk-actions');

    tbody.innerHTML = '';

    if (fleetState.length === 0) {
        tbody.parentElement.style.display = 'none';
        emptyState.classList.remove('hidden');
        bulkActions.classList.add('hidden');
        return;
    }

    tbody.parentElement.style.display = '';
    emptyState.classList.add('hidden');
    bulkActions.classList.remove('hidden');

    fleetState.forEach((ep, i) => {
        const sys = ep.system || {};
        const updCount = ep.applicable ? ep.applicable.length : 0;

        let statusBadge = '';
        if (ep.status === 'Scanning') statusBadge = '<span class="badge badge-scanning"><i class="fa-solid fa-spinner fa-spin"></i> Scanning</span>';
        else if (ep.status === 'Online') statusBadge = '<span class="badge badge-success"><i class="fa-solid fa-circle-check"></i> Online</span>';
        else if (ep.status === 'Not Applicable') statusBadge = '<span class="badge badge-na"><i class="fa-solid fa-ban"></i> Not HP</span>';
        else if (ep.status === 'Error') statusBadge = '<span class="badge badge-danger"><i class="fa-solid fa-circle-xmark"></i> Error</span>';
        else statusBadge = '<span class="badge badge-danger"><i class="fa-solid fa-circle-xmark"></i> Offline</span>';

        let updBadge = '';
        if (ep.status === 'Scanning') updBadge = '<span class="text-muted text-sm">—</span>';
        else if (ep.status === 'Not Applicable') updBadge = '<span class="badge badge-na">N/A</span>';
        else if (updCount > 0) {
            const deployingCount = (ep.applicable || []).filter(u => u.deploying).length;
            if (deployingCount > 0) {
                updBadge = `<span class="badge badge-deploying">${deployingCount} Deploying</span> <span class="badge badge-warning">${updCount} Available</span>`;
            } else {
                updBadge = `<span class="badge badge-warning">${updCount} Available</span>`;
            }
        }
        else if (ep.status === 'Online') updBadge = '<span class="badge badge-success">Up to date</span>';
        else updBadge = '<span class="text-muted text-sm">N/A</span>';

        const model = sys.model || 'N/A';
        const platform = sys.platform ? `ID: ${sys.platform}` : '';
        const os = sys.os || 'N/A';

        const row = document.createElement('tr');
        row.className = i === selectedEndpointIndex ? 'selected' : '';
        row.innerHTML = `
            <td><input type="checkbox" class="row-checkbox" data-index="${i}"></td>
            <td><div class="host-cell"><span class="host-primary">${ep.hostname}</span>${sys.serial ? `<span class="host-sub">SN: ${sys.serial}</span>` : ''}</div></td>
            <td>${statusBadge}</td>
            <td><div class="host-cell"><span>${model}</span>${platform ? `<span class="host-sub">${platform}</span>` : ''}</div></td>
            <td>${os}</td>
            <td>${updBadge}</td>
            <td class="table-actions">
                <button onclick="event.stopPropagation(); selectEndpoint(${i})" title="More Info"><i class="fa-solid fa-circle-info"></i></button>
                <button onclick="event.stopPropagation(); scanEndpoint(${i})" title="Rescan"><i class="fa-solid fa-rotate"></i></button>
                <button class="danger" onclick="event.stopPropagation(); removeEndpoint(${i})" title="Remove"><i class="fa-solid fa-trash"></i></button>
            </td>`;
        row.addEventListener('click', (e) => {
            if (e.target.tagName === 'INPUT' || e.target.tagName === 'BUTTON' || e.target.tagName === 'I') return;
            // Toggle checkbox on row click
            const cb = row.querySelector('.row-checkbox');
            if (cb) cb.checked = !cb.checked;
        });
        tbody.appendChild(row);
    });
}

function selectEndpoint(index) {
    selectedEndpointIndex = index;
    renderFleetTable();
    renderDetailPanel(index);
}

function renderDetailPanel(index) {
    const panel = document.getElementById('fleet-detail-panel');
    const content = document.getElementById('detail-content');
    const ep = fleetState[index];
    if (!ep) { panel.classList.add('hidden'); return; }

    document.getElementById('detail-hostname').textContent = ep.hostname;
    panel.classList.remove('hidden');

    const sys = ep.system || {};
    const applicable = ep.applicable || [];
    const deploying = applicable.filter(u => u.deploying);
    const available = applicable.filter(u => !u.deploying);
    const history = ep.deployHistory || [];

    // Progress ring: only count verified installs
    const totalUpdates = applicable.length + history.length;
    const verifiedCount = history.length;
    const installedPct = totalUpdates > 0 ? Math.round((verifiedCount / totalUpdates) * 100) : (ep.status === 'Online' ? 100 : 0);
    const ringCirc = 2 * Math.PI * 22;
    const ringOffset = ringCirc - (installedPct / 100) * ringCirc;

    content.innerHTML = `
        <div class="detail-section">
            <div class="detail-section-title">System Information</div>
            <div class="info-grid">
                <div class="info-item"><span class="info-label">Model</span><span class="info-value">${sys.model || 'N/A'}</span></div>
                <div class="info-item"><span class="info-label">Platform</span><span class="info-value">${sys.platform || 'N/A'}</span></div>
                <div class="info-item"><span class="info-label">Serial</span><span class="info-value">${sys.serial || 'N/A'}</span></div>
                <div class="info-item"><span class="info-label">OS</span><span class="info-value">${sys.os || 'N/A'}</span></div>
            </div>
        </div>

        <div class="detail-section">
            <div class="detail-section-title">Deployment Progress</div>
            <div class="progress-ring-container">
                <svg class="progress-ring" viewBox="0 0 50 50">
                    <circle class="progress-ring-bg" cx="25" cy="25" r="22"/>
                    <circle class="progress-ring-fill" cx="25" cy="25" r="22" style="stroke-dashoffset:${ringOffset}; stroke:${installedPct >= 100 ? 'var(--success)' : 'var(--accent-primary)'}"/>
                    <text class="progress-ring-text" x="25" y="25">${installedPct}%</text>
                </svg>
                <div class="progress-info">
                <span class="progress-title">${verifiedCount} of ${totalUpdates || 0} verified</span>
                    <span class="progress-sub">${deploying.length} deploying, ${available.length} available</span>
                </div>
            </div>
        </div>

        <div class="detail-section">
            <div class="detail-section-title" style="display:flex; justify-content:space-between; align-items:center;">
                <span>Available Updates (${available.length})</span>
                ${available.length > 0 ? '<label class="select-all-label"><input type="checkbox" id="detail-select-all" onchange="toggleAllUpdates(this)"> <span>All</span></label>' : ''}
            </div>
            ${available.length > 0 ? `<div class="update-list">
                ${available.map((u, idx) => {
        const catBadge = u.category && u.category !== 'Unknown'
            ? getCategoryBadge(u.category)
            : `<span class="badge badge-info">${u.type}</span>`;
        const name = u.name || u.id;
        return `<div class="update-item-wrap">
                        <div class="update-item clickable" onclick="toggleUpdateDetail(this)">
                            <div class="update-item-left" style="flex-direction:row; align-items:center; gap:0.5rem;">
                                <input type="checkbox" class="update-checkbox" data-update-idx="${idx}" onclick="event.stopPropagation();">
                                <div style="display:flex; flex-direction:column; gap:0.1rem; min-width:0;">
                                    <span class="update-id">${u.id}</span>
                                    <span class="update-name text-muted text-sm">${name !== u.id ? name : ''}</span>
                                </div>
                            </div>
                            ${catBadge}
                        </div>
                        <div class="update-detail hidden">
                            <div class="info-grid" style="gap:0.4rem;">
                                <div class="info-item"><span class="info-label">Name</span><span class="info-value">${u.name || 'N/A'}</span></div>
                                <div class="info-item"><span class="info-label">Category</span><span class="info-value">${u.category || u.type || 'N/A'}</span></div>
                                <div class="info-item"><span class="info-label">Version</span><span class="info-value">${u.version || 'N/A'}</span></div>
                                <div class="info-item"><span class="info-label">Released</span><span class="info-value">${u.date || 'N/A'}</span></div>
                            </div>
                        </div>
                    </div>`;
    }).join('')}
            </div>
            <button class="btn btn-sm btn-accent" onclick="deploySelectedFromDetail(${index})" style="width:100%; margin-top:0.75rem;">
                <i class="fa-solid fa-bolt"></i> Deploy Selected Updates
            </button>` : '<p class="text-muted text-sm">No new updates available.</p>'}
        </div>

        ${deploying.length > 0 ? (() => {
            const taskIds = [...new Set(deploying.map(u => u.deployTaskId).filter(Boolean))];
            return `<div class="detail-section">
            <div class="detail-section-title" style="display:flex; justify-content:space-between; align-items:center;">
                <span>Deploying (${deploying.length})</span>
                ${taskIds.length > 0 ? `<button class="btn btn-sm btn-abort" onclick="abortDeployForEndpoint(${index})" title="Abort all active deployments"><i class="fa-solid fa-stop"></i> Abort</button>` : ''}
            </div>
            <div class="update-list">
                ${deploying.map(u => `<div class="update-item">
                    <div><span class="update-id">${u.id}</span><br><span class="text-muted text-sm">${u.name || ''}</span></div>
                    <span class="badge badge-deploying"><i class="fa-solid fa-clock"></i> Deploying</span>
                </div>`).join('')}
            </div>
            <p class="text-muted text-sm" style="margin-top:0.5rem;">Rescan to verify installation status.</p>
        </div>`;
        })() : ''}

        <div class="detail-section">
            <div class="detail-section-title">Install History (${history.length})</div>
            ${history.length > 0 ? `<div class="update-list">
            ${history.map(h => `<div class="update-item">
                    <div><span class="update-id">${h.id}</span><br><span class="text-muted text-sm">${h.name || ''} — ${h.deployedAt || h.date || ''}</span></div>
                    <span class="badge badge-success"><i class="fa-solid fa-circle-check"></i> Verified</span>
                </div>`).join('')}
            </div>` : '<p class="text-muted text-sm">No deployments recorded.</p>'}
        </div>

        <div style="margin-top:1rem;">
            <button class="btn btn-sm btn-primary" onclick="scanEndpoint(${index})" style="width:100%"><i class="fa-solid fa-rotate"></i> Rescan Endpoint</button>
        </div>
    `;
}

function toggleAllUpdates(masterCheckbox) {
    const checkboxes = document.querySelectorAll('#detail-content .update-checkbox');
    checkboxes.forEach(cb => cb.checked = masterCheckbox.checked);
}

async function deploySelectedFromDetail(endpointIndex) {
    const ep = fleetState[endpointIndex];
    if (!ep) return;

    const checked = [...document.querySelectorAll('#detail-content .update-checkbox:checked')];
    if (checked.length === 0) return showToast('No updates selected. Check the ones you want to deploy.', true);

    // Get indices of non-deploying available items only
    const available = (ep.applicable || []).map((u, i) => ({ ...u, _origIdx: i })).filter(u => !u.deploying);
    const selectedPkgs = [];
    checked.forEach(cb => {
        const avIdx = parseInt(cb.dataset.updateIdx);
        if (available[avIdx]) selectedPkgs.push(available[avIdx]);
    });

    if (selectedPkgs.length === 0) return showToast('No valid updates selected.', true);

    showLoading(`Deploying ${selectedPkgs.length} update(s) to ${ep.hostname}...`);
    const res = await apiCall('/deploy', 'POST', { targets: ep.hostname, packages: selectedPkgs });
    hideLoading();

    if (res && res.success !== false) {
        // Store the task ID for tracking
        const deployTaskId = res.taskId || null;

        // Mark items as 'Deploying' (keep in applicable, flag them)
        selectedPkgs.forEach(pkg => {
            const item = ep.applicable[pkg._origIdx];
            if (item) {
                item.deploying = true;
                item.deployTaskId = deployTaskId;
            }
        });
        if (deployTaskId) {
            if (!ep.activeTaskIds) ep.activeTaskIds = [];
            ep.activeTaskIds.push(deployTaskId);
        }

        saveInventory();
        renderDetailPanel(endpointIndex);
        renderFleetTable();
        updateDashboard();
        showToast(`${selectedPkgs.length} update(s) deploying to ${ep.hostname}. Check Tasks tab for progress.`);

        // Auto-switch to Tasks tab and start polling
        document.querySelectorAll('.nav-btn').forEach(b => b.classList.remove('active'));
        const tasksBtn = document.querySelector('.nav-btn[data-tab="tasks"]');
        if (tasksBtn) tasksBtn.classList.add('active');
        document.querySelectorAll('.tab-pane').forEach(p => p.classList.remove('active'));
        const tasksTab = document.getElementById('tab-tasks');
        if (tasksTab) tasksTab.classList.add('active');
        loadTasks();
    } else {
        showToast(res.message || 'Deployment failed.', true);
    }
}

function getCategoryBadge(category) {
    const cat = (category || '').toLowerCase();
    if (cat.includes('bios') || cat.includes('firmware')) return '<span class="badge badge-danger"><i class="fa-solid fa-microchip"></i> BIOS/Firmware</span>';
    if (cat.includes('driver')) return '<span class="badge badge-info"><i class="fa-solid fa-plug"></i> Driver</span>';
    if (cat.includes('software') || cat.includes('utility')) return '<span class="badge badge-warning"><i class="fa-solid fa-box"></i> Software</span>';
    return `<span class="badge badge-info">${category}</span>`;
}

function toggleUpdateDetail(el) {
    const detail = el.nextElementSibling;
    if (detail) {
        detail.classList.toggle('hidden');
        el.classList.toggle('expanded');
    }
}

// ── Close detail panel ──
document.getElementById('btn-close-detail').addEventListener('click', () => {
    document.getElementById('fleet-detail-panel').classList.add('hidden');
    selectedEndpointIndex = -1;
    renderFleetTable();
});

// ── Add Endpoint ──
function closeAddModal() {
    document.getElementById('add-endpoint-modal').classList.add('hidden');
    document.getElementById('modal-error').textContent = '';
    document.getElementById('modal-error').classList.add('hidden');
}

async function confirmAddEndpoint() {
    const hostname = document.getElementById('endpoint-hostname').value.trim();
    const errorEl = document.getElementById('modal-error');

    if (!hostname) {
        errorEl.textContent = 'Please enter a hostname or IP address.';
        errorEl.classList.remove('hidden');
        return;
    }

    // Prevent duplicates (case-insensitive)
    if (fleetState.find(e => e.hostname.toLowerCase() === hostname.toLowerCase())) {
        errorEl.textContent = '"' + hostname + '" already exists in the fleet.';
        errorEl.classList.remove('hidden');
        return;
    }

    errorEl.classList.add('hidden');

    closeAddModal();

    const index = fleetState.length;
    fleetState.push({ hostname, status: 'Scanning', system: null, applicable: [], deployHistory: [] });
    renderFleetTable();
    saveInventory();

    await scanEndpoint(index);
}

document.getElementById('btn-add-endpoint').addEventListener('click', () => {
    document.getElementById('add-endpoint-modal').classList.remove('hidden');
    document.getElementById('endpoint-hostname').value = '';
    document.getElementById('modal-error').textContent = '';
    document.getElementById('modal-error').classList.add('hidden');
    document.getElementById('endpoint-hostname').focus();
});
document.getElementById('btn-close-modal').addEventListener('click', closeAddModal);
document.getElementById('btn-cancel-modal').addEventListener('click', closeAddModal);
document.getElementById('btn-confirm-add').addEventListener('click', confirmAddEndpoint);

// Keyboard: Enter to confirm, Escape to cancel
document.getElementById('endpoint-hostname').addEventListener('keydown', (e) => {
    if (e.key === 'Enter') { e.preventDefault(); confirmAddEndpoint(); }
    if (e.key === 'Escape') { e.preventDefault(); closeAddModal(); }
});

// ── Scan Endpoint ──
async function scanEndpoint(index) {
    const endpoint = fleetState[index];
    if (!endpoint) return;

    // Remember deploying items before rescan
    const previousDeploying = (endpoint.applicable || []).filter(u => u.deploying);

    fleetState[index].status = 'Scanning';
    renderFleetTable();

    const res = await apiCall('/fleet/scan', 'POST', { hostname: endpoint.hostname });

    if (res.status) {
        fleetState[index].status = res.status;
    } else if (!res.success) {
        fleetState[index].status = res.message ? 'Error' : 'Offline';
    }
    if (res.system) fleetState[index].system = res.system;

    // Update applicable from scan results — show TRUE state from HP
    if (res.applicable) {
        // Preserve deploying flag for items still being deployed
        const currentDeploying = new Map((endpoint.applicable || []).filter(u => u.deploying).map(u => [u.id, u]));

        fleetState[index].applicable = res.applicable.map(u => {
            const dep = currentDeploying.get(u.id);
            if (dep) {
                return { ...u, deploying: true, deployTaskId: dep.deployTaskId };
            }
            return u;
        });
    }

    if (!res.success && res.message && !res.status) {
        showToast(`Scan failed for ${endpoint.hostname}: ${res.message}`, true);
    }

    renderFleetTable();
    saveInventory();
    updateDashboard();

    if (selectedEndpointIndex === index) renderDetailPanel(index);
}

// ── Auto-verify deploys when tasks complete ──
let _previousTaskStates = {};

function reconcileFleetWithTasks(tasks) {
    let fleetChanged = false;
    for (const t of tasks) {
        const prevState = _previousTaskStates[t.id];
        // If task just transitioned from Running to Completed/Aborted/Failed
        if (prevState === 'Running' && t.state !== 'Running') {
            const prog = t.progress || { results: [] };
            const results = prog.results || [];
            // Build a set of package IDs that actually succeeded (exit code 0, 3010, 1641)
            const succeededIds = new Set(
                results.filter(r => r.exitCode === 0 || r.exitCode === 3010 || r.exitCode === 1641)
                    .map(r => r.id)
            );
            const failedIds = new Set(
                results.filter(r => r.exitCode !== 0 && r.exitCode !== 3010 && r.exitCode !== 1641)
                    .map(r => r.id)
            );

            for (const ep of fleetState) {
                if (!ep.applicable) continue;
                // Find deploying items belonging to this task
                let deployingItems = ep.applicable.filter(u => u.deploying && u.deployTaskId === t.id);
                if (deployingItems.length === 0 && ep.activeTaskIds && ep.activeTaskIds.includes(t.id)) {
                    deployingItems = ep.applicable.filter(u => u.deploying);
                }
                if (deployingItems.length === 0) continue;

                if (!ep.deployHistory) ep.deployHistory = [];
                const historyIds = new Set(ep.deployHistory.map(h => h.id));

                if (results.length > 0) {
                    // We have per-package results — only verify confirmed successes
                    deployingItems.forEach(dep => {
                        if (succeededIds.has(dep.id) && !historyIds.has(dep.id)) {
                            const result = results.find(r => r.id === dep.id);
                            ep.deployHistory.push({
                                ...dep,
                                deploying: false,
                                exitCode: result ? result.exitCode : 0,
                                status: result ? result.status : 'Success',
                                deployedAt: new Date().toLocaleString()
                            });
                        } else {
                            // Failed or not in results — clear deploying flag so user can retry
                            dep.deploying = false;
                            dep.deployTaskId = null;
                            if (failedIds.has(dep.id)) {
                                dep.lastError = results.find(r => r.id === dep.id)?.status || 'Failed';
                            }
                        }
                    });
                    // Remove verified items from applicable
                    ep.applicable = ep.applicable.filter(u => !succeededIds.has(u.id) || historyIds.has(u.id));
                } else {
                    // No per-package results — just clear deploying flag, don't falsely verify
                    deployingItems.forEach(dep => {
                        dep.deploying = false;
                        dep.deployTaskId = null;
                    });
                }

                ep.activeTaskIds = (ep.activeTaskIds || []).filter(id => id !== t.id);
                fleetChanged = true;
            }
        }
        _previousTaskStates[t.id] = t.state;
    }
    if (fleetChanged) {
        saveInventory();
        renderFleetTable();
        updateDashboard();
        if (selectedEndpointIndex >= 0) renderDetailPanel(selectedEndpointIndex);
    }
}

// ── Delete Confirmation ──
function removeEndpoint(index) {
    const ep = fleetState[index];
    if (!ep) return;
    pendingDeleteIndex = index;
    document.getElementById('delete-endpoint-name').textContent = ep.hostname;
    document.getElementById('delete-confirm-modal').classList.remove('hidden');
}

function closeDeleteModal() {
    document.getElementById('delete-confirm-modal').classList.add('hidden');
    pendingDeleteIndex = -1;
}

function confirmDelete() {
    if (pendingDeleteIndex < 0) return;
    const index = pendingDeleteIndex;
    fleetState.splice(index, 1);
    if (selectedEndpointIndex === index) {
        selectedEndpointIndex = -1;
        document.getElementById('fleet-detail-panel').classList.add('hidden');
    } else if (selectedEndpointIndex > index) {
        selectedEndpointIndex--;
    }
    renderFleetTable();
    saveInventory();
    updateDashboard();
    closeDeleteModal();
    showToast('Endpoint removed.');
}

document.getElementById('btn-confirm-delete').addEventListener('click', confirmDelete);
document.getElementById('btn-cancel-delete').addEventListener('click', closeDeleteModal);
document.getElementById('btn-close-delete-modal').addEventListener('click', closeDeleteModal);
document.getElementById('delete-confirm-modal').addEventListener('keydown', (e) => {
    if (e.key === 'Enter') { e.preventDefault(); confirmDelete(); }
    if (e.key === 'Escape') { e.preventDefault(); closeDeleteModal(); }
});
// Focus the modal when opened so keyboard events work
const deleteModalObserver = new MutationObserver(() => {
    if (!document.getElementById('delete-confirm-modal').classList.contains('hidden')) {
        document.getElementById('btn-confirm-delete').focus();
    }
});
deleteModalObserver.observe(document.getElementById('delete-confirm-modal'), { attributes: true, attributeFilter: ['class'] });

// ── Network Scan ──
document.getElementById('btn-network-scan').addEventListener('click', async () => {
    showLoading('Scanning network for HP devices...');
    showToast('Network scan started — this may take a minute.');
    const res = await apiCall('/fleet/discover', 'POST');
    hideLoading();
    if (res && res.devices && res.devices.length > 0) {
        let added = 0;
        for (const dev of res.devices) {
            if (!fleetState.find(e => e.hostname === dev.hostname)) {
                fleetState.push({
                    hostname: dev.hostname,
                    status: dev.status || 'Pending',
                    system: dev.system || null,
                    applicable: [],
                    deployHistory: []
                });
                added++;
            }
        }
        renderFleetTable();
        saveInventory();
        updateDashboard();
        showToast(`Found ${res.devices.length} devices, added ${added} new endpoints.`);
    } else {
        showToast(res.message || 'No HP devices found on the network.', !res.success);
    }
});

// ── Select All ──
document.getElementById('fleet-select-all').addEventListener('change', (e) => {
    document.querySelectorAll('#fleet-table-body .row-checkbox').forEach(cb => cb.checked = e.target.checked);
});

// ── Bulk Deploy ──
document.getElementById('btn-bulk-deploy').addEventListener('click', async () => {
    const checked = [...document.querySelectorAll('#fleet-table-body .row-checkbox:checked')];
    if (checked.length === 0) return showToast('No endpoints selected.', true);
    showLoading('Deploying updates...');
    for (const cb of checked) {
        const idx = parseInt(cb.dataset.index);
        const ep = fleetState[idx];
        if (ep && ep.applicable && ep.applicable.length > 0) {
            await apiCall('/deploy', 'POST', { targets: ep.hostname, packages: ep.applicable });
        }
    }
    hideLoading();
    showToast('Deployment batch complete.');
});

// ── Bulk Delete ──
document.getElementById('btn-bulk-delete').addEventListener('click', () => {
    const checked = [...document.querySelectorAll('#fleet-table-body .row-checkbox:checked')];
    if (checked.length === 0) return showToast('No endpoints selected.', true);
    const names = checked.map(cb => fleetState[parseInt(cb.dataset.index)]?.hostname).filter(Boolean);
    showActionConfirm(
        `Remove ${checked.length} Endpoint(s)`,
        `Are you sure you want to remove these endpoints from the fleet?<br><br><strong>${names.join(', ')}</strong>`,
        () => {
            const indices = checked.map(cb => parseInt(cb.dataset.index)).sort((a, b) => b - a);
            indices.forEach(i => fleetState.splice(i, 1));
            selectedEndpointIndex = -1;
            document.getElementById('fleet-detail-panel').classList.add('hidden');
            renderFleetTable();
            saveInventory();
            updateDashboard();
            showToast(`Removed ${indices.length} endpoint(s) from the fleet.`);
        }
    );
});

// ── Logs ──
let lastLogContent = '';
async function fetchLogs() {
    const res = await apiCall('/logs', 'GET');
    if (res && res.logs) {
        const logContent = Array.isArray(res.logs) ? res.logs.join('\n') : String(res.logs);
        if (logContent !== lastLogContent) {
            logText.textContent = logContent;
            logText.scrollTop = logText.scrollHeight;
            lastLogContent = logContent;
        }
    }
}
document.getElementById('btn-refresh-logs').addEventListener('click', fetchLogs);

// ── Repository ──
document.getElementById('btn-set-path').addEventListener('click', async () => {
    const path = repoPathInput.value.trim();
    if (!path) return;
    const res = await apiCall('/path', 'POST', { path });
    showToast(res.message || 'Path saved.');
});
document.getElementById('btn-open-path').addEventListener('click', async () => {
    await apiCall('/path/open', 'POST');
});
document.getElementById('btn-info').addEventListener('click', async () => {
    const res = await apiCall('/info', 'GET');
    document.getElementById('repo-info-text').textContent = res.info || JSON.stringify(res, null, 2);
});

// ── Action Confirmation Modal ──
function showActionConfirm(title, description, onConfirm) {
    document.getElementById('action-confirm-title').textContent = title;
    document.getElementById('action-confirm-desc').innerHTML = description;
    pendingActionCallback = onConfirm;
    document.getElementById('action-confirm-modal').classList.remove('hidden');
    document.getElementById('btn-confirm-action').focus();
}

function closeActionModal() {
    document.getElementById('action-confirm-modal').classList.add('hidden');
    pendingActionCallback = null;
}

document.getElementById('btn-confirm-action').addEventListener('click', () => {
    closeActionModal();
    if (pendingActionCallback) pendingActionCallback();
});
document.getElementById('btn-cancel-action').addEventListener('click', closeActionModal);
document.getElementById('btn-close-action-modal').addEventListener('click', closeActionModal);
document.getElementById('action-confirm-modal').addEventListener('keydown', (e) => {
    if (e.key === 'Enter') { e.preventDefault(); document.getElementById('btn-confirm-action').click(); }
    if (e.key === 'Escape') { e.preventDefault(); closeActionModal(); }
});

// ── Settings actions ──
document.getElementById('btn-sync').addEventListener('click', () => {
    showActionConfirm(
        'Run Sync',
        'This will synchronize your local repository with HP\'s cloud servers, downloading any new or updated SoftPaqs that match your fleet\'s platform IDs.<br><br><strong>This may take several minutes</strong> depending on the number of packages and your internet speed.',
        async () => {
            // Gather unique platform IDs from the fleet
            const platforms = [...new Set(
                fleetState
                    .filter(e => e.system && e.system.platform && e.system.platform !== 'Unknown')
                    .map(e => e.system.platform)
            )];
            showLoading('Running Sync...');
            const res = await apiCall('/sync', 'POST', { platforms });
            hideLoading();
            showToast(res.message || 'Sync task started. Check Tasks tab for progress.');
        }
    );
});
document.getElementById('btn-cleanup').addEventListener('click', () => {
    showActionConfirm(
        'Run Cleanup',
        'This will remove superseded and obsolete SoftPaqs from your local repository, freeing up disk space.<br><br>Only packages that have been replaced by newer versions will be removed. <strong>Active packages will not be affected.</strong>',
        async () => {
            showLoading('Running Cleanup...');
            const res = await apiCall('/cleanup', 'POST');
            hideLoading();
            showToast(res.message || 'Cleanup complete.');
        }
    );
});
document.getElementById('btn-init').addEventListener('click', () => {
    showActionConfirm(
        'Initialize Repository',
        'This will initialize (or re-initialize) the HP repository at the configured path. It creates the required folder structure and configuration files.<br><br><strong>If a repository already exists at this path, it will be reset.</strong>',
        async () => {
            showLoading('Initializing Repository...');
            const res = await apiCall('/init', 'POST');
            hideLoading();
            showToast(res.message || 'Repository initialized.');
        }
    );
});
document.getElementById('btn-shutdown').addEventListener('click', async () => {
    if (!confirm('Are you sure you want to shut down the server?')) return;
    await apiCall('/shutdown', 'POST');
    showToast('Server shutting down...');
});

// ── Settings Form ──
document.getElementById('settings-form').addEventListener('submit', async (e) => {
    e.preventDefault();
    const settings = {
        OnRemoteFileNotFound: document.getElementById('s-missing').value,
        OfflineCacheMode: document.getElementById('s-cache').value,
        RepositoryReport: document.getElementById('s-report').value,
    };
    const res = await apiCall('/settings', 'POST', settings);
    showToast(res.message || 'Settings applied.');
});

// ── Tasks Tab ──
let tasksInterval = null;

async function loadTasks() {
    const res = await apiCall('/tasks', 'GET');
    const container = document.getElementById('tasks-container');
    if (!res || !res.tasks || res.tasks.length === 0) {
        container.innerHTML = '<p class="text-muted text-sm" style="padding:1rem;">No tasks have been run yet.</p>';
        return;
    }

    // Sort: running first, then most recent
    const tasks = res.tasks.sort((a, b) => {
        if (a.state === 'Running' && b.state !== 'Running') return -1;
        if (b.state === 'Running' && a.state !== 'Running') return 1;
        return (b.id || 0) - (a.id || 0);
    });

    // Auto-update fleet when deploy tasks finish
    reconcileFleetWithTasks(tasks);

    container.innerHTML = tasks.map(t => {
        const stateClass = t.state === 'Running' ? 'badge-scanning' : t.state === 'Completed' ? 'badge-success' : t.state === 'Aborted' ? 'badge-aborted' : 'badge-danger';
        const stateIcon = t.state === 'Running' ? '<i class="fa-solid fa-spinner fa-spin"></i> ' : t.state === 'Completed' ? '<i class="fa-solid fa-circle-check"></i> ' : t.state === 'Aborted' ? '<i class="fa-solid fa-ban"></i> ' : '<i class="fa-solid fa-circle-xmark"></i> ';
        const msgs = (t.messages || []).slice(-30);
        const prog = t.progress || { total: 0, completed: 0, percentage: 0, currentStep: '', results: [] };
        const results = prog.results || [];

        // Progress bar — always show
        const pct = prog.percentage || 0;
        const barColor = t.state === 'Completed' ? 'var(--success)' : t.state === 'Failed' ? 'var(--danger)' : t.state === 'Aborted' ? 'var(--text-secondary)' : 'var(--accent-primary)';
        const stepText = prog.currentStep ? prog.currentStep.replace(/\[Task \d+\]\s*/, '').replace(/\[(\d+)\/(\d+)\]\s*/, '[$1/$2] ') : (t.state === 'Running' ? 'Initializing...' : '');
        const packageInfo = prog.total > 0 ? `<span class="text-sm" style="color:var(--text-secondary); margin-left:0.5rem;">Package ${prog.completed} of ${prog.total}</span>` : '';
        const progressBar = `
            <div class="task-progress-bar" style="margin-top:0.5rem;">
                <div class="task-progress-fill" style="width:${pct}%; background:${barColor};"></div>
            </div>
            <div style="display:flex; justify-content:space-between; align-items:center; margin-top:0.3rem;">
                <span class="text-sm" style="color:var(--text-primary); font-weight:500;">${stepText}${packageInfo}</span>
                <span class="text-sm" style="color:${barColor}; font-weight:600;">${pct}%</span>
            </div>`;

        // Per-package results table (PDQ-style)
        let resultsHtml = '';
        if (results.length > 0) {
            resultsHtml = `<div class="task-results">
                <div class="task-results-header">
                    <span>Package</span><span>Exit Code</span><span>Status</span>
                </div>
                ${results.map(r => {
                const statusClass = r.exitCode === 0 ? 'result-success' : (r.exitCode === 3010 || r.exitCode === 1641) ? 'result-reboot' : 'result-error';
                return `<div class="task-result-row ${statusClass}">
                        <span class="result-pkg">${r.id}</span>
                        <span class="result-code">${r.exitCode}</span>
                        <span class="result-status">${r.status}</span>
                    </div>`;
            }).join('')}
            </div>`;
        }

        // Log display — open by default for running tasks, collapsed for others
        const isRunning = t.state === 'Running';
        const logHtml = msgs.length > 0 ? `
            <details class="task-log-details" ${isRunning ? 'open' : ''}>
                <summary class="text-muted text-sm"><i class="fa-solid fa-terminal" style="margin-right:0.3rem;"></i>Log Output (${msgs.length} entries)</summary>
                <div class="task-log"><pre>${msgs.join('\n')}</pre></div>
            </details>` : (isRunning ? '<div class="task-log"><pre class="text-muted">Waiting for output...</pre></div>' : '');

        // Abort button for running tasks
        const abortBtn = t.state === 'Running' ? `<button class="btn btn-sm btn-abort" onclick="abortTask(${t.id})"><i class="fa-solid fa-stop"></i> Abort</button>` : '';

        // Elapsed time
        let elapsedStr = '';
        if (t.startTime) {
            const start = new Date(t.startTime);
            const now = new Date();
            const diffSec = Math.floor((now - start) / 1000);
            if (diffSec < 60) elapsedStr = `${diffSec}s`;
            else if (diffSec < 3600) elapsedStr = `${Math.floor(diffSec / 60)}m ${diffSec % 60}s`;
            else elapsedStr = `${Math.floor(diffSec / 3600)}h ${Math.floor((diffSec % 3600) / 60)}m`;
        }

        // Message count summary
        const errCount = msgs.filter(m => m.includes('[X] ERROR')).length;
        const warnCount = msgs.filter(m => m.includes('[!] WARNING')).length;
        let statusSummary = '';
        if (errCount > 0) statusSummary += `<span style="color:var(--danger); font-size:0.72rem; margin-left:0.4rem;"><i class="fa-solid fa-circle-xmark"></i> ${errCount} error${errCount > 1 ? 's' : ''}</span>`;
        if (warnCount > 0) statusSummary += `<span style="color:var(--warning); font-size:0.72rem; margin-left:0.4rem;"><i class="fa-solid fa-triangle-exclamation"></i> ${warnCount} warning${warnCount > 1 ? 's' : ''}</span>`;

        return `<div class="task-card glass-card ${t.state === 'Aborted' ? 'task-aborted' : t.state === 'Failed' ? 'task-failed' : t.state === 'Completed' ? 'task-completed' : ''}">
            <div class="task-card-header">
                <div>
                    <span class="task-name">${t.name || 'Task ' + t.id}</span>
                    <span class="text-muted text-sm" style="margin-left:0.5rem;">${t.startTime || ''}</span>
                    ${elapsedStr ? `<span class="task-elapsed">${elapsedStr}</span>` : ''}
                    ${statusSummary}
                </div>
                <div style="display:flex; align-items:center; gap:0.5rem;">
                    ${abortBtn}
                    <span class="badge ${stateClass}">${stateIcon}${t.state}</span>
                </div>
            </div>
            ${progressBar}
            ${resultsHtml}
            ${logHtml}
        </div>`;
    }).join('');

    // Auto-poll while any task is running AND user is on tasks tab
    const hasRunning = tasks.some(t => t.state === 'Running');
    const onTasksTab = document.querySelector('.nav-btn.active')?.dataset.tab === 'tasks';
    if (hasRunning && !tasksInterval && onTasksTab) {
        tasksInterval = setInterval(loadTasks, 3000);
    } else if (!hasRunning && tasksInterval) {
        clearInterval(tasksInterval);
        tasksInterval = null;
    }
}

document.getElementById('btn-refresh-tasks').addEventListener('click', loadTasks);

async function abortTask(taskId) {
    const res = await apiCall('/tasks/abort', 'POST', { taskId });
    if (res && res.success !== false) {
        showToast(res.message || `Task ${taskId} aborted.`);
    } else {
        showToast(res.message || 'Failed to abort task.', true);
    }
    loadTasks();
}

async function abortDeployForEndpoint(endpointIndex) {
    const ep = fleetState[endpointIndex];
    if (!ep) return;
    const deploying = (ep.applicable || []).filter(u => u.deploying);
    const taskIds = [...new Set(deploying.map(u => u.deployTaskId).filter(Boolean))];
    if (taskIds.length === 0) {
        // No task IDs — just clear the deploying flags
        ep.applicable.forEach(u => { u.deploying = false; });
        renderDetailPanel(endpointIndex);
        renderFleetTable();
        updateDashboard();
        showToast('Deployment flags cleared.');
        return;
    }
    for (const tid of taskIds) {
        await apiCall('/tasks/abort', 'POST', { taskId: tid });
    }
    // Clear deploying flags
    ep.applicable.forEach(u => { u.deploying = false; delete u.deployTaskId; });
    ep.activeTaskIds = [];
    saveInventory();
    renderDetailPanel(endpointIndex);
    renderFleetTable();
    updateDashboard();
    loadTasks();
    showToast(`Aborted ${taskIds.length} deployment(s) for ${ep.hostname}.`);
}

// ── Start ──
initApp();
