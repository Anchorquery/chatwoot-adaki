#!/bin/sh

set -x

# Remove a potentially pre-existing server.pid for Rails.
rm -rf /app/tmp/pids/server.pid
rm -rf /app/tmp/cache/*

echo "Waiting for postgres to become ready...."

# Let DATABASE_URL env take presedence over individual connection params.
# This is done to avoid printing the DATABASE_URL in the logs
$(docker/entrypoints/helpers/pg_database_url.rb)
PG_READY="pg_isready -h $POSTGRES_HOST -p $POSTGRES_PORT -U $POSTGRES_USERNAME"

until $PG_READY
do
  sleep 2;
done

echo "Database ready to accept connections."

# Install missing gems only in non-production (production image is pre-built).
if [ "$RAILS_ENV" != "production" ]; then
  bundle install
  BUNDLE="bundle check"
  until $BUNDLE
  do
    sleep 2;
  done
fi

# Run migrations + seed on every start. db:chatwoot_prepare is idempotent:
# loads schema + seeds on first boot, migrates on subsequent boots.
# Only the "rails" web container should do this. Sidekiq sets SKIP_DB_PREPARE=true.
if [ "$SKIP_DB_PREPARE" != "true" ]; then
  echo "Running db:chatwoot_prepare..."
  bundle exec rails db:chatwoot_prepare
fi

# Execute the main process of the container
exec "$@"
