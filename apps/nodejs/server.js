'use strict';

const cluster = require('node:cluster');
const express = require('express');
const Redis = require('ioredis');

const WORKERS = parseInt(process.env.WORKERS || '4', 10);
const PORT = parseInt(process.env.PORT || '8080', 10);

if (cluster.isPrimary) {
  for (let i = 0; i < WORKERS; i++) {
    cluster.fork();
  }
  cluster.on('exit', () => {
    cluster.fork();
  });
} else {
  const redis = new Redis({
    host: process.env.VALKEY_HOST || 'valkey',
    port: 6379,
  });

  const app = express();
  app.get('/', async (req, res) => {
    res.type('text/plain').send(String(await redis.incr('counter')));
  });

  app.listen(PORT);
}
