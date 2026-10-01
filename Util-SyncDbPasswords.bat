@echo off

set NAMESPACE=highlight

rem Postgres only runs its init scripts (POSTGRES_PASSWORD, init-db.sh's CREATE USER statements)
rem once, against an empty data directory. If a PVC survives a `helm upgrade`/reinstall (they're
rem annotated helm.sh/resource-policy: keep) while the passwords in values*.yaml change, the
rem *configured* password and the *actual* one stored in Postgres drift apart - cvedb/keycloak/
rem the portal then fail to authenticate even though the Secret looks correct.
rem This resets the actual Postgres role passwords to match whatever is currently deployed,
rem without touching the PVC or any data.
rem
rem Passwords are read from postgres-0's env vars (injected from the Secret - the chart-managed one
rem or existingSecret). If the Secret changed since postgres-0 started (e.g. rotated in an external
rem secret store), restart it first so it picks up the new values:
rem   kubectl rollout restart statefulset postgres -n %NAMESPACE%
rem
rem CAUTION: passwords are piped through cmd's `echo`, so avoid values containing characters
rem cmd treats specially (& | < > ^ %% ") when using this script.

echo Syncing Postgres role passwords to match the currently-applied Helm values...
echo (no data or PVCs are touched)
echo.

echo [1/2] Resetting the postgres superuser password...
for /f "delims=" %%P in ('kubectl exec -n %NAMESPACE% postgres-0 -- printenv POSTGRES_PASSWORD') do set "PGPASS=%%P"
if "%PGPASS%"=="" (
    echo Could not read POSTGRES_PASSWORD from postgres-0 - aborting.
    exit /b 1
)
echo ALTER ROLE postgres WITH PASSWORD '%PGPASS%'; | kubectl exec -i -n %NAMESPACE% postgres-0 -- psql -U postgres -v ON_ERROR_STOP=1
set "PGPASS="

echo [2/2] Resetting highlight / highlight_root / keycloak role passwords (from postgres-0's HL_DB_* env vars)...
kubectl exec -n %NAMESPACE% postgres-0 -- bash -c "grep -E 'getenv|CREATE USER' /docker-entrypoint-initdb.d/init-db.sh | sed 's/CREATE USER/ALTER USER/' | psql -U postgres -v ON_ERROR_STOP=1"

echo.
echo Done. Restarting cvedb/highlightportal/keycloak so they open fresh connections...
kubectl rollout restart deployment cvedb highlightportal keycloak -n %NAMESPACE%
