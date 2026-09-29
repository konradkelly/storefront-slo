import http from 'k6/http';
import { check, sleep } from 'k6';

const BASE = __ENV.BASE_URL || 'http://localhost:8080';

export const options = {
  vus: Number(__ENV.VUS || 5),
  duration: __ENV.DURATION || '30m',
};

// 402 (payment failed) and 409 (out of stock) are expected business outcomes, not test errors.
http.setResponseCallback(http.expectedStatuses(200, 201, 402, 409));

const json = { headers: { 'Content-Type': 'application/json' } };

export function setup() {
  const res = http.get(`${BASE}/products`);
  return { ids: res.json().map((p) => p.id) };
}

export default function (data) {
  const cartId = `vu${__VU}-it${__ITER}`;
  const pick = () => data.ids[Math.floor(Math.random() * data.ids.length)];

  // Browse
  http.get(`${BASE}/products`);
  http.get(`${BASE}/products/${pick()}`);
  sleep(Math.random());

  // Add 1 to 3 items
  const count = 1 + Math.floor(Math.random() * 3);
  for (let i = 0; i < count; i++) {
    const quantity = 1 + Math.floor(Math.random() * 2);
    http.post(`${BASE}/cart/items`, JSON.stringify({ cartId, productId: pick(), quantity }), json);
  }

  // Not every shopper checks out
  if (Math.random() < 0.7) {
    const res = http.post(`${BASE}/orders`, JSON.stringify({ cartId }), json);
    check(res, { 'checkout handled': (r) => [201, 402, 409].includes(r.status) });
  }

  sleep(1 + Math.random() * 2);
}
