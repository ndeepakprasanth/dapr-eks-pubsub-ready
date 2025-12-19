
const express = require('express');
const app = express();
app.use(express.json({ type: ['application/json', 'application/*+json'] }));

// Dapr will POST events to this endpoint as per Subscription
app.post('/orders', async (req, res) => {
  const ce = req.body;
  console.log('OrderService received event:', JSON.stringify(ce));
  // Respond 200 to ack the message; non-2xx triggers redelivery per Dapr/backing broker policy
  res.status(200).send();
});

app.get('/', (req, res) => res.send('OrderService OK'));

const port = process.env.PORT || 8090;
app.listen(port, () => console.log(`OrderService listening on ${port}`));
