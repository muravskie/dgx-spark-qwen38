"use strict";
/* Overview-only renderer. Server telemetry contains names and counts, not prompts. */
window.renderImageLab = function renderImageLab(data){
  const put = (id, value) => { const node = document.getElementById(id); if (node) node.textContent = value; };
  const timeOf = ms => {
    if (typeof ms !== 'number' || !Number.isFinite(ms)) return null;
    return new Date(ms).toLocaleTimeString([], {hour: 'numeric', minute: '2-digit', second: '2-digit', hour12: false});
  };
  const controller = data.controller;
  const queue = data.queue;
  const history = data.history;
  const last = history && history.last;
  const running = controller && controller.runtime === 'running';
  const state = !controller ? (data.controller_error ? 'controller unavailable' : 'not registered')
    : controller.ownership !== 'managed' ? 'externally owned'
    : !running ? controller.runtime : controller.healthy === true ? 'API ready' : 'API unavailable';
  const chip = document.getElementById('image-lane-chip');
  if (chip){ chip.textContent = state; chip.className = 'cap ' + (running && controller.healthy === true ? 'ok' : running ? 'warn' : ''); }
  put('image-owner', controller ? (controller.ownership === 'managed' ? 'spark-model-controller' : controller.ownership || 'unknown') : 'unknown');
  put('image-runtime', controller ? controller.runtime : 'unknown');
  put('image-roles', controller && controller.roles ? controller.roles.join(' · ') : 'unknown');
  put('image-api', controller ? (controller.healthy === true ? 'responding' : controller.healthy === false ? 'not responding' : 'not checked') : 'unknown');
  put('image-version', 'ComfyUI · Qwen Image generation and edit');
  const link = document.getElementById('image-open');
  if (link){
    // ComfyUI listens on the same host as Cockpit, port 8188. Avoid a server-supplied URL.
    link.href = `${location.protocol}//${location.hostname}:8188/`;
  }
  put('image-running', queue ? String(queue.running) : 'unknown');
  put('image-pending', queue ? String(queue.pending) : 'unknown');
  const model = queue && queue.running_model ? queue.running_model : last && last.model;
  put('image-model-label', queue && queue.running_model ? 'Running workflow model' : 'Last workflow model');
  put('image-model', model || (queue && queue.running ? 'model not reported' : 'none observed'));
  const lastTime = last && timeOf(last.finished_ms);
  put('image-last-result', last ? `${last.status || 'unknown'}${lastTime ? ` · ${lastTime}` : ''}` : 'none observed');
  put('image-last-duration', last && last.duration_seconds != null ? `${last.duration_seconds.toFixed(1)} s` : 'unknown');
  const windowStart = history && timeOf(history.window_started_ms);
  put('image-recent', history ? `${history.successful} succeeded · ${history.failed} failed (${history.sample_size} recent${windowStart ? ` · since ${windowStart}` : ''})` : 'unknown');
  put('image-queue-note', data.queue_error ? 'ComfyUI queue unavailable' : data.history_error ? 'Recent history unavailable' :
    'API readiness does not verify that a workflow can load weights and finish.');
};
