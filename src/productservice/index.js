
const express = require('express');
const axios = require('axios');

const app = express();
app.use(express.json());

const DAPR_HTTP_PORT = process.env.DAPR_HTTP_PORT || 3500;
const PUBSUB_NAME = process.env.PUBSUB_NAME || 'snssqs-pubsub';
const TOPIC_NAME = process.env.TOPIC_NAME || 'orders';

app.post('/publish', async (req, res) => {
  const payload = req.body && Object.keys(req.body).length ? req.body : { orderId: Date.now(), source: 'ProductService' };
  try {
    const url = `http://localhost:${DAPR_HTTP_PORT}/v1.0/publish/${PUBSUB_NAME}/${TOPIC_NAME}`;
    const r = await axios.post(url, payload, { headers: { 'Content-Type': 'application/json' }});
    res.status(200).json({ ok: true, published: payload });
  } catch (err) {
    console.error('Publish failed:', err.response?.data || err.message);
    res.status(500).json({ ok: false, error: err.message, details: err.response?.data });
  }
});

app.get('/', (req, res) => res.send('ProductService OK'));

const port = process.env.PORT || 8080;
app.listen(port, () => console.log(`ProductService listening on ${port}, publishing to topic '${TOPIC_NAME}' via pubsub '${PUBSUB_NAME}'`));
