#!/bin/sh
set -e

exec bundle exec puma -w 4 -t 8:8 -b tcp://0.0.0.0:8080 config.ru
