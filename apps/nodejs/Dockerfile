FROM node:24-alpine

WORKDIR /app

COPY package.json ./
RUN npm install --omit=dev

COPY server.js entrypoint.sh ./
RUN chmod +x entrypoint.sh

# Express instrumentation adds its own middleware/router/handler spans on top
# of the http span; keep only http and ioredis so each request still produces
# exactly two spans.
ENV OTEL_NODE_ENABLED_INSTRUMENTATIONS=http,ioredis
ENV OTEL_SERVICE_NAME=bench-nodejs

EXPOSE 8080
ENTRYPOINT ["./entrypoint.sh"]
