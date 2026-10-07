import http from 'k6/http';
import { check, sleep } from 'k6';
import { Rate, Trend } from 'k6/metrics';

const base = __ENV.BASE_URL || 'http://storefront-api.storefront.svc:8080';
const checkoutErrors = new Rate('checkout_error_ratio');
const checkoutLatency = new Trend('checkout_latency', true);
const runId = __ENV.RUN_ID || String(Date.now());

export const options = {
  vus: Number(__ENV.VUS || 5),
  duration: __ENV.DURATION || '2m',
  thresholds: __ENV.WARMUP === 'true' ? {} : {
    checks: ['rate==1'],
    checkout_error_ratio: ['rate<0.005'],
    checkout_latency: ['p(99)<500'],
    'http_req_failed{endpoint:catalog}': ['rate<0.001'],
    'http_req_failed{endpoint:cart}': ['rate<0.001'],
  },
};

// 402 is expected at HTTP level but explicitly bad in the checkout SLI below.
http.setResponseCallback(http.expectedStatuses(200, 201, 402, 409));
const headers = { 'Content-Type': 'application/json' };

export default function () {
  const products = http.get(`${base}/products`, { tags: { endpoint: 'catalog' } });
  if (!check(products, { 'catalog served': r => r.status === 200 })) {
    sleep(1);
    return;
  }
  const productId = products.json()[__VU % products.json().length].id;
  const cartId = `smoke-${runId}-${__VU}-${__ITER}`;
  const added = http.post(`${base}/cart/items`, JSON.stringify({ cartId, productId, quantity: 1 }),
    { headers, tags: { endpoint: 'cart' } });
  if (!check(added, { 'item added': r => r.status === 200 || r.status === 201 })) {
    sleep(1);
    return;
  }
  const cart = http.get(`${base}/cart/${cartId}`, { tags: { endpoint: 'cart' } });
  check(cart, { 'cart served': r => r.status === 200 });
  const order = http.post(`${base}/orders`, JSON.stringify({ cartId }),
    { headers, tags: { endpoint: 'checkout' } });
  checkoutLatency.add(order.timings.duration);
  // Same exclusions as docs/slo.md. Transport failures count as bad.
  if (order.status !== 400 && order.status !== 409) {
    checkoutErrors.add(order.status === 0 || order.status === 402 || order.status >= 500);
  }
  // CI has deterministic payments and abundant stock: a 409/400 is a broken fixture.
  check(order, { 'order created': r => r.status === 201 });
  sleep(1);
}
