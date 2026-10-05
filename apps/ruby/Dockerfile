FROM ruby:3.4-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
        build-essential \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

COPY Gemfile ./
RUN bundle install

COPY app.rb otel.rb config.ru entrypoint.sh ./
RUN chmod +x entrypoint.sh

ENV RUBYOPT=--yjit

EXPOSE 8080
ENTRYPOINT ["./entrypoint.sh"]
