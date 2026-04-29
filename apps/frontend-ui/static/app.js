// ============================================================
// Observability PoC Store - Frontend JS
// Calls backend APIs and renders results
// Browser Agent / CloudWatch RUM captures these interactions
// ============================================================

let timeline = [];
let requestCount = 0;

function getRequestId() {
  return 'req-' + Date.now() + '-' + Math.random().toString(36).substr(2, 6);
}

async function runScenario(scenario) {
  const reqId = getRequestId();
  const start = performance.now();
  showLoading(scenario);

  try {
    const resp = await fetch(`/api/checkout/${scenario}`, {
      headers: { 'X-Request-Id': reqId }
    });
    const data = await resp.json();
    const latency = Math.round(performance.now() - start);

    if (!resp.ok) {
      showResult(scenario, null, latency, resp.status, reqId);
      addTimeline(scenario, 'error', latency, resp.status);
    } else {
      showResult(scenario, data, latency, 200, reqId);
      addTimeline(scenario, data.has_error ? 'error' : (latency > 1500 ? 'slow' : 'success'), latency, 200);
    }
  } catch (err) {
    const latency = Math.round(performance.now() - start);
    showResult(scenario, null, latency, 0, reqId, err.message);
    addTimeline(scenario, 'error', latency, 0);
  }
}

async function runSearch() {
  const reqId = getRequestId();
  const start = performance.now();
  const queries = ['shoes', 'laptop', 'headphones', 'camera', 'watch'];
  const q = queries[Math.floor(Math.random() * queries.length)];

  showLoading('search');
  try {
    const resp = await fetch(`/api/search?q=${q}`, {
      headers: { 'X-Request-Id': reqId }
    });
    const data = await resp.json();
    const latency = Math.round(performance.now() - start);
    showResult('search', data, latency, resp.status, reqId);
    addTimeline('search', 'success', latency, 200);
  } catch (err) {
    const latency = Math.round(performance.now() - start);
    showResult('search', null, latency, 0, reqId, err.message);
    addTimeline('search', 'error', latency, 0);
  }
}

async function runUserJourney() {
  const reqId = getRequestId();
  const start = performance.now();
  showLoading('user-journey');

  try {
    const resp = await fetch('/api/user-journey', {
      headers: { 'X-Request-Id': reqId }
    });
    const data = await resp.json();
    const latency = Math.round(performance.now() - start);
    showResult('user-journey', data, latency, resp.status, reqId);
    addTimeline('user-journey', latency > 2000 ? 'slow' : 'success', latency, 200);
  } catch (err) {
    const latency = Math.round(performance.now() - start);
    showResult('user-journey', null, latency, 0, reqId, err.message);
    addTimeline('user-journey', 'error', latency, 0);
  }
}

async function runLoadBurst() {
  const scenarios = ['normal', 'slow-inventory', 'payment-error', 'external-slow', 'random'];
  for (let i = 0; i < scenarios.length; i++) {
    setTimeout(() => runScenario(scenarios[i]), i * 400);
  }
}

// Browser testing - intentional JS error for RUM testing
function triggerJsError() {
  addTimeline('js-error', 'error', 0, 0);
  setTimeout(() => {
    throw new Error('[PoC] Intentional JS error for RUM/Browser Agent testing - ' + new Date().toISOString());
  }, 100);
}

// Slow render simulation for LCP/INP testing
function triggerSlowRender() {
  const start = performance.now();
  addTimeline('slow-render', 'slow', 0, 0);

  // Block main thread to simulate slow render
  const container = document.getElementById('result-content');
  container.innerHTML = '<div class="text-yellow-400 text-sm py-4">Simulating slow render...</div>';

  // CPU-heavy work (blocks main thread ~500ms)
  let sum = 0;
  for (let i = 0; i < 50000000; i++) {
    sum += Math.sqrt(i);
  }
  const duration = Math.round(performance.now() - start);

  container.innerHTML = `
    <div class="space-y-2">
      <div class="text-yellow-400 font-semibold">Slow Render Simulated</div>
      <div class="text-sm text-slate-400">Main thread blocked for <span class="text-yellow-300 font-mono">${duration}ms</span></div>
      <div class="text-xs text-slate-500">Check Browser Agent / CloudWatch RUM for INP/LCP impact</div>
    </div>
  `;
}

function showLoading(scenario) {
  requestCount++;
  const loadingEl = document.getElementById('loading-state');
  const contentEl = document.getElementById('result-content');
  const badge = document.getElementById('result-badge');

  loadingEl.classList.remove('hidden');
  contentEl.innerHTML = '';
  badge.classList.add('hidden');
  contentEl.appendChild(loadingEl);
}

function showResult(scenario, data, latency, status, reqId, errorMsg) {
  const contentEl = document.getElementById('result-content');
  const badge = document.getElementById('result-badge');
  const loadingEl = document.getElementById('loading-state');

  loadingEl.classList.add('hidden');

  const isError = status >= 400 || status === 0 || (data && data.has_error);
  const isSlow = latency > 1500;

  // Update badge
  badge.classList.remove('hidden', 'bg-green-900', 'bg-red-900', 'bg-amber-900', 'text-green-400', 'text-red-400', 'text-amber-400');
  if (isError) {
    badge.className = 'text-xs font-bold px-3 py-1 rounded-full bg-red-900 text-red-300';
    badge.textContent = `ERROR ${status}`;
  } else if (isSlow) {
    badge.className = 'text-xs font-bold px-3 py-1 rounded-full bg-amber-900 text-amber-300';
    badge.textContent = `SLOW ${latency}ms`;
  } else {
    badge.className = 'text-xs font-bold px-3 py-1 rounded-full bg-green-900 text-green-300';
    badge.textContent = `OK ${latency}ms`;
  }

  // Build trace path
  const tracePath = buildTracePath(data);

  contentEl.innerHTML = `
    <div class="grid grid-cols-3 gap-3 mb-4">
      <div class="bg-slate-900 rounded-lg p-3 text-center">
        <div class="text-xs text-slate-500 mb-1">Scenario</div>
        <div class="font-semibold text-sm">${scenario}</div>
      </div>
      <div class="bg-slate-900 rounded-lg p-3 text-center">
        <div class="text-xs text-slate-500 mb-1">Latency</div>
        <div class="font-semibold text-sm ${isSlow ? 'text-amber-400' : 'text-green-400'}">${latency}ms</div>
      </div>
      <div class="bg-slate-900 rounded-lg p-3 text-center">
        <div class="text-xs text-slate-500 mb-1">Status</div>
        <div class="font-semibold text-sm ${isError ? 'text-red-400' : 'text-green-400'}">${status || 'Error'}</div>
      </div>
    </div>

    <div class="mb-3">
      <div class="text-xs text-slate-500 mb-2">Call Path</div>
      <div class="trace-path bg-slate-900 rounded-lg p-3">
        ${tracePath}
      </div>
    </div>

    ${data && data.trace_id ? `
    <div class="mb-3 bg-slate-900 rounded-lg p-3">
      <div class="text-xs text-slate-500 mb-1">Trace ID</div>
      <div class="font-mono text-xs text-blue-400">${data.trace_id}</div>
      <div class="text-xs text-slate-500 mt-1">→ Use this to search in Application Signals or New Relic</div>
    </div>
    ` : ''}

    ${data && data.steps ? `
    <div class="bg-slate-900 rounded-lg p-3">
      <div class="text-xs text-slate-500 mb-2">Service Steps</div>
      <div class="space-y-1">
        ${(data.steps || []).map(s => `
          <div class="flex items-center justify-between text-xs ${s.error ? 'text-red-400' : s.latency_ms > 1000 ? 'text-amber-400' : 'text-slate-300'}">
            <span>${s.service}</span>
            <span class="font-mono">${s.latency_ms}ms ${s.error ? '❌' : s.latency_ms > 1000 ? '⏱' : '✓'}</span>
          </div>
        `).join('')}
      </div>
    </div>
    ` : ''}

    ${errorMsg || (data && data.error) ? `
    <div class="bg-red-950 border border-red-800 rounded-lg p-3">
      <div class="text-xs text-red-400">${errorMsg || data.error}</div>
    </div>
    ` : ''}

    <div class="text-xs text-slate-600 mt-2 font-mono">req-id: ${reqId}</div>
  `;
}

function buildTracePath(data) {
  const nodes = ['frontend-ui', 'backend-for-frontend', 'order-api'];
  if (data && data.steps) {
    const serviceNodes = data.steps.map(s => {
      const cls = s.error ? 'border-red-700 text-red-400' : s.latency_ms > 1000 ? 'border-amber-700 text-amber-400' : '';
      return `<span class="trace-node ${cls}">${s.service}</span>`;
    });
    return serviceNodes.join('<span class="trace-arrow">→</span>');
  }
  return nodes.map(n => `<span class="trace-node">${n}</span>`).join('<span class="trace-arrow">→</span>');
}

function addTimeline(scenario, type, latency, status) {
  const now = new Date().toLocaleTimeString('ja-JP');
  const icons = { success: '✓', error: '✗', slow: '⏱' };
  const colors = { success: 'text-green-400', error: 'text-red-400', slow: 'text-amber-400' };

  timeline.unshift({ scenario, type, latency, status, time: now });
  if (timeline.length > 20) timeline.pop();

  const container = document.getElementById('timeline');
  if (timeline.length === 1) container.innerHTML = '';

  container.innerHTML = timeline.map(item => `
    <div class="timeline-item ${item.type} flex items-center justify-between">
      <div class="flex items-center gap-2">
        <span class="${colors[item.type] || 'text-slate-400'} text-xs">${icons[item.type] || '?'}</span>
        <span class="text-xs text-slate-300">${item.scenario}</span>
      </div>
      <div class="flex items-center gap-3 text-xs text-slate-500">
        ${item.latency > 0 ? `<span class="${item.latency > 1500 ? 'text-amber-500' : ''}">${item.latency}ms</span>` : ''}
        <span>${item.status || ''}</span>
        <span>${item.time}</span>
      </div>
    </div>
  `).join('');
}

function clearTimeline() {
  timeline = [];
  document.getElementById('timeline').innerHTML =
    '<div class="text-slate-600 text-xs text-center py-4">No requests yet</div>';
}

// Global error handler for RUM testing
window.addEventListener('error', function(e) {
  console.warn('[PoC RUM test] Caught error:', e.message);
});
window.addEventListener('unhandledrejection', function(e) {
  console.warn('[PoC RUM test] Unhandled rejection:', e.reason);
});
