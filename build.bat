@echo off
setlocal enabledelayedexpansion

REM Exit if Docker is not installed
where docker >nul 2>&1
if errorlevel 1 (
    echo Docker not found. Please install Docker Desktop before running this script.
    pause
    exit /b 1
)

REM Check for existing containers
set SKIP_PG_PROD=false
set SKIP_API_SERVER=false

for /f "delims=" %%C in ('docker ps -a --format "{{.Names}}"') do (
    if /i "%%C"=="pg_prod" set SKIP_PG_PROD=true
    if /i "%%C"=="fno_api_server" set SKIP_API_SERVER=true
)

if "%SKIP_PG_PROD%"=="true" (
    echo Container pg_prod already exists. Skipping creation.
) else (
    echo Container pg_prod does not exist. Will create.
)

if "%SKIP_API_SERVER%"=="true" (
    echo Container fno_api_server already exists. Skipping creation.
) else (
    echo Container fno_api_server does not exist. Will create.
)

REM Pull PostgreSQL image
docker pull postgres:15

REM Create Docker network if not exists
docker network inspect fno_net >nul 2>&1
if errorlevel 1 (
    docker network create fno_net
)

REM Write Dockerfile.pg
> Dockerfile.pg (
    echo FROM postgres:15
    echo USER root
    echo RUN apt-get update ^&^& apt-get install -y python3 python3-pip libpq-dev python3-dev python3-psycopg2
    echo WORKDIR /docker-entrypoint-initdb.d/
    echo COPY src/build_mock.py .
    echo COPY src/init_postgres.py .
    echo COPY src/ ./src/
    echo RUN python3 build_mock.py
    echo USER postgres
)

REM Build custom Postgres image
docker build -f Dockerfile.pg -t fno_pg_custom .

REM Run PostgreSQL container if not skipped
if "%SKIP_PG_PROD%"=="false" (
    docker run -d --name pg_prod --network fno_net -e POSTGRES_PASSWORD=prodpassword -e POSTGRES_USER=produser -e POSTGRES_DB=proddb -p 5465:5432 fno_pg_custom

    REM Wait for DB to be ready
    echo Waiting for PostgreSQL to be ready...
    :waitloop
    docker exec pg_prod pg_isready -U produser >nul 2>&1
    if errorlevel 1 (
        timeout /t 1 >nul
        goto waitloop
    )

    docker exec pg_prod python3 /docker-entrypoint-initdb.d/init_postgres.py
)

REM Write Dockerfile.api
> Dockerfile.api (
    echo FROM node:18
    echo WORKDIR /app
    echo COPY src/ .
    echo RUN apt-get update ^&^& apt-get install -y python3
    echo RUN python3 build_mock.py
    echo RUN npm init -y ^&^& npm install express pg
    echo EXPOSE 3000
    echo CMD ["node", "fno_data__server"]
)

REM Build API server image if not skipped
if "%SKIP_API_SERVER%"=="false" (
    docker build -f Dockerfile.api -t fno_api_server .
)

REM Run API server container if not skipped
if "%SKIP_API_SERVER%"=="false" (
    docker run -d --name fno_api_server --network fno_net -p 3000:3000 fno_api_server
)

REM Setup Python virtual environment
if not exist ".venv" (
    echo Creating Python virtual environment...
    python -m venv .venv
    echo To activate the virtual environment, run: .venv\Scripts\activate
) else (
    echo Python virtual environment already exists.
)

REM Final instructions
echo.
echo Setup complete.
echo PostgreSQL is running on port 5465.
echo API server is running on port 3000.
echo.
echo To continue:
echo 1. Activate the virtual environment: .venv\Scripts\activate
echo 2. Install dependencies: pip install -r requirements-dev.txt
echo 3. Enter the dbt directory: cd dbt
echo.
echo TLDR: `source .venv/bin/activate && pip3 install -r requirements-dev.txt && cd dbt`

echo .
pause
