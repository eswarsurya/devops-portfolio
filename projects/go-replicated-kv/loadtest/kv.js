// k6 load test for the kv cluster.
//
//   MODE=steady  constant rate for a while; thresholds match the SLO, so the
//                run fails if the cluster misses it at this load.
//   MODE=step    a series of constant-rate steps, one after another, to find
//                where latency bends and requests start to drop (capacity).
//   MODE=soak    background traffic with no thresholds (used by the game day).
//
// Every request goes to a random node; any node can coordinate. 80% reads,
// 20% writes of 128-byte values over KEYS keys, written once in setup().
import http from 'k6/http';
import { check } from 'k6';

const TARGETS = (__ENV.TARGETS || 'http://kv1:8080,http://kv2:8080,http://kv3:8080').split(',');
const MODE = __ENV.MODE || 'steady';
const KEYS = Number(__ENV.KEYS || 1000);
const WRITE_RATIO = Number(__ENV.WRITE_RATIO || 0.2);
const STEADY_RATE = Number(__ENV.STEADY_RATE || 200);
const STEADY_SECONDS = Number(__ENV.STEADY_SECONDS || 60);
const STEPS = (__ENV.STEPS || '200,400,800,1600,3200').split(',').map(Number);
const STEP_SECONDS = Number(__ENV.STEP_SECONDS || 20);
const SOAK_RATE = Number(__ENV.SOAK_RATE || 50);
const SOAK_SECONDS = Number(__ENV.SOAK_SECONDS || 1200);
const OUT = __ENV.OUT || '';
const LABEL = __ENV.LABEL || MODE;

const VALUE = 'v'.repeat(128);
const P95_MS = 100; // latency SLO threshold
const MAX_ERROR_RATE = 0.001; // availability SLO: 99.9%

function stepName(rate) {
  return `step_${String(rate).padStart(5, '0')}`;
}

function buildScenarios() {
  const vus = { preAllocatedVUs: 50, maxVUs: 500 };
  if (MODE === 'steady') {
    return { steady: { executor: 'constant-arrival-rate', rate: STEADY_RATE, timeUnit: '1s', duration: `${STEADY_SECONDS}s`, ...vus } };
  }
  if (MODE === 'soak') {
    return { soak: { executor: 'constant-arrival-rate', rate: SOAK_RATE, timeUnit: '1s', duration: `${SOAK_SECONDS}s`, ...vus } };
  }
  const s = {};
  STEPS.forEach((rate, i) => {
    s[stepName(rate)] = {
      executor: 'constant-arrival-rate', rate, timeUnit: '1s',
      duration: `${STEP_SECONDS}s`, startTime: `${i * STEP_SECONDS}s`, ...vus,
    };
  });
  return s;
}

function buildThresholds() {
  const t = {};
  if (MODE === 'steady') {
    t['http_req_failed{scenario:steady}'] = [`rate<${MAX_ERROR_RATE}`];
    t['http_req_duration{scenario:steady}'] = [`p(95)<${P95_MS}`];
    t['http_reqs{scenario:steady}'] = ['count>=0'];
    t['dropped_iterations{scenario:steady}'] = ['count>=0'];
  } else if (MODE === 'step') {
    // Always-true thresholds: they only make k6 report each step on its own.
    for (const rate of STEPS) {
      const n = stepName(rate);
      t[`http_req_duration{scenario:${n}}`] = ['max>=0'];
      t[`http_req_failed{scenario:${n}}`] = ['rate>=0'];
      t[`http_reqs{scenario:${n}}`] = ['count>=0'];
      t[`dropped_iterations{scenario:${n}}`] = ['count>=0'];
    }
  }
  return t;
}

export const options = {
  scenarios: buildScenarios(),
  thresholds: buildThresholds(),
  summaryTrendStats: ['med', 'p(95)', 'p(99)', 'max'],
  discardResponseBodies: true,
  setupTimeout: '120s',
};

function pick(list) {
  return list[Math.floor(Math.random() * list.length)];
}

export function setup() {
  // Write every key once so reads hit existing data, not 404s.
  const batch = [];
  for (let i = 0; i < KEYS; i++) {
    batch.push(['PUT', `${pick(TARGETS)}/kv/load-${i}`, VALUE, { tags: { name: 'setup' } }]);
    if (batch.length === 50 || i === KEYS - 1) {
      http.batch(batch.splice(0));
    }
  }
}

export default function () {
  const key = `load-${Math.floor(Math.random() * KEYS)}`;
  const url = `${pick(TARGETS)}/kv/${key}`;
  let res;
  if (Math.random() < WRITE_RATIO) {
    res = http.put(url, VALUE, { tags: { name: 'kv', op: 'put' }, timeout: '5s' });
  } else {
    res = http.get(url, { tags: { name: 'kv', op: 'get' }, timeout: '5s' });
  }
  check(res, { 'status 200': (r) => r.status === 200 });
}

function fmt(x, digits = 1) {
  return x === undefined || x === null || Number.isNaN(x) ? 'n/a' : Number(x).toFixed(digits);
}

function row(data, scenario, targetRate, seconds) {
  const m = (name) => data.metrics[`${name}{scenario:${scenario}}`];
  const dur = m('http_req_duration');
  const reqs = m('http_reqs');
  const failed = m('http_req_failed');
  const dropped = m('dropped_iterations');
  const count = reqs ? reqs.values.count : 0;
  return {
    scenario,
    target: targetRate,
    achieved: count / seconds,
    p50: dur ? dur.values.med : undefined,
    p95: dur ? dur.values['p(95)'] : undefined,
    p99: dur ? dur.values['p(99)'] : undefined,
    errorPct: failed ? failed.values.rate * 100 : undefined,
    dropped: dropped ? dropped.values.count : 0,
  };
}

export function handleSummary(data) {
  let rows = [];
  if (MODE === 'steady') {
    rows = [row(data, 'steady', STEADY_RATE, STEADY_SECONDS)];
  } else if (MODE === 'step') {
    rows = STEPS.map((rate) => row(data, stepName(rate), rate, STEP_SECONDS));
  }
  let md = `### Load test: ${LABEL}\n\n`;
  if (rows.length) {
    md += '| scenario | target req/s | achieved req/s | p50 ms | p95 ms | p99 ms | errors % | dropped |\n';
    md += '|---|---:|---:|---:|---:|---:|---:|---:|\n';
    for (const r of rows) {
      md += `| ${r.scenario} | ${r.target} | ${fmt(r.achieved)} | ${fmt(r.p50, 2)} | ${fmt(r.p95, 2)} | ${fmt(r.p99, 2)} | ${fmt(r.errorPct, 3)} | ${r.dropped} |\n`;
    }
  }
  if (MODE === 'steady') {
    const failedThresholds = Object.entries(data.metrics)
      .filter(([, v]) => v.thresholds && Object.values(v.thresholds).some((t) => !t.ok))
      .map(([k]) => k);
    md += failedThresholds.length
      ? `\nSLO thresholds FAILED: ${failedThresholds.join(', ')}\n`
      : `\nSLO thresholds passed: p95 < ${P95_MS} ms and errors < ${MAX_ERROR_RATE * 100}% at ${STEADY_RATE} req/s.\n`;
  }
  const out = { stdout: md };
  if (OUT) {
    out[`${OUT}/${LABEL}.md`] = md;
    out[`${OUT}/${LABEL}.json`] = JSON.stringify({ label: LABEL, mode: MODE, rows, metrics: data.metrics }, null, 2);
  }
  return out;
}
