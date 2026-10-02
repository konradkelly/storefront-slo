import http from 'k6/http';
import { check, sleep } from 'k6';

const BASE = __ENV.BASE_URL || 'http://localhost:8080';

// browse (default): a realistic shop. Most sessions only look, ~15% add to cart, about half of those
//   check out. Catalog to cart traffic is roughly 15:1. Use it for SLO baselines.
// checkout-stress: every session fills a cart and 70% check out. Use it for the saga vs. single-tx
//   latency experiment, which needs many concurrent checkouts to produce row-lock contention.
const PROFILE = __ENV.PROFILE || 'browse';
if (!['browse', 'checkout-stress'].includes(PROFILE)) {
  throw new Error(`Unknown PROFILE "${PROFILE}". Use browse or checkout-stress.`);
}

export const options = {
  vus: Number(__ENV.VUS || 5),
  duration: __ENV.DURATION || '30m',
  tags: { profile: PROFILE },
};

// 402 (payment failed) and 409 (out of stock) are expected business outcomes, not test errors.
http.setResponseCallback(http.expectedStatuses(200, 201, 402, 409));

const json = { headers: { 'Content-Type': 'application/json' } };

export function setup() {
  const res = http.get(`${BASE}/products`);
  return { ids: res.json().map((p) => p.id) };
}

function addToCart(cartId, productId) {
  const quantity = 1 + Math.floor(Math.random() * 2);
  http.post(`${BASE}/cart/items`, JSON.stringify({ cartId, productId, quantity }), json);
}

function checkout(cartId) {
  const res = http.post(`${BASE}/orders`, JSON.stringify({ cartId }), json);
  check(res, { 'checkout handled': (r) => [201, 402, 409].includes(r.status) });
}

function browseSession(cartId, pick) {
  http.get(`${BASE}/products`);
  sleep(0.5 + Math.random());

  // Look at 3 to 8 products
  const views = 3 + Math.floor(Math.random() * 6);
  for (let i = 0; i < views; i++) {
    http.get(`${BASE}/products/${pick()}`);
    sleep(0.5 + Math.random());
  }

  // Most shoppers leave without buying
  if (Math.random() >= 0.15) {
    return;
  }
  const count = 1 + Math.floor(Math.random() * 3);
  for (let i = 0; i < count; i++) {
    addToCart(cartId, pick());
  }
  http.get(`${BASE}/cart/${cartId}`);

  if (Math.random() < 0.5) {
    checkout(cartId);
  }
}

function checkoutStressSession(cartId, pick) {
  // Browse
  http.get(`${BASE}/products`);
  http.get(`${BASE}/products/${pick()}`);
  sleep(Math.random());

  // Add 1 to 3 items
  const count = 1 + Math.floor(Math.random() * 3);
  for (let i = 0; i < count; i++) {
    addToCart(cartId, pick());
  }

  // Not every shopper checks out
  if (Math.random() < 0.7) {
    checkout(cartId);
  }
}

export default function (data) {
  const cartId = `vu${__VU}-it${__ITER}`;
  const pick = () => data.ids[Math.floor(Math.random() * data.ids.length)];

  if (PROFILE === 'checkout-stress') {
    checkoutStressSession(cartId, pick);
  } else {
    browseSession(cartId, pick);
  }

  sleep(1 + Math.random() * 2);
}
