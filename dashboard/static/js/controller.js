"use strict";
/* Controller-owned workloads and telemetry carried across the v1.19 redesign. */
function setTitleAndText(id, value, title){ setText(id, value); setTitle(id, title); }
function rThroughput(d){
  if (d.available === false){
    ['prefillrate', 'cacherate', 'genrate', 'throughputmedian'].forEach(id => setTitleAndText(id, 'unavailable', d.unavailable || 'The engine metrics endpoint is unavailable.'));
    return;
  }
  const c = d.current || {}, recent = d.recent_median || {};
  const rate = key => c[key] == null ? 'idle' : `${c[key].toFixed(1)} tok/s`;
  const med = key => recent[key] == null ? '' : `; median ${recent[key].toFixed(1)} over ${d.sample_count || 0} windows`;
  const medianText = ['prefill_compute', 'prefill_cache', 'generation']
    .filter(key => recent[key] != null)
    .map(key => `${key === 'prefill_compute' ? 'pre' : key === 'prefill_cache' ? 'cache' : 'gen'} ${key === 'generation' ? recent[key].toFixed(1) : Math.round(recent[key])}`)
    .join(' / ');
  const wholeRate = key => c[key] == null ? 'idle' : `${Math.round(c[key])} tok/s`;
  setTitleAndText('prefillrate', wholeRate('prefill_compute'), `Uncached prefill now${med('prefill_compute')}`);
  setTitleAndText('cacherate', wholeRate('prefill_cache'), `Cached prompt processing now${med('prefill_cache')}`);
  setTitleAndText('genrate', rate('generation'), `Generation now${med('generation')}`);
  setTitleAndText('throughputmedian', medianText || 'warming up', 'Median over the last 10 telemetry windows, in tok/s');
}
on('throughput', rThroughput);
on('image_lab', d => window.renderImageLab(d));
afterApply(() => {
  const managed = controllerOwnsQwen();
  if (managed){
    setText('st-update', `cd ${F.config.repo_dir || '<repo>'} && ./dashboard/install-dashboard.sh`);
    LCARDS.forEach((c, unit) => {
      c.load.hidden = true; c.tsel.hidden = true;
      if (unit !== U27){ c.start.hidden = true; c.stop.hidden = true; }
      else { c.why.hidden = false; setText(c.why, 'Qwen lifecycle is owned by spark-model-controller. Start and Stop use its local API.'); }
    });
  }
  show('oc-fitbtn', !F.agent?.remote);
});
