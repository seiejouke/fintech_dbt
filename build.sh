#!/bin/bash

# Exit on error
set -e

# Function to check if Docker is installed, and offer to install if missing
check_docker() {
    if ! command -v docker &> /dev/null; then
        echo "Docker not found. Please install Docker before running this script."
        read -p "Would you like to attempt to install Docker automatically? (y/n): " yn
        case $yn in
            [Yy]* )
                if [[ "$OSTYPE" == "linux-gnu"* ]]; then
                    curl -fsSL https://get.docker.com -o get-docker.sh
                    sh get-docker.sh
                    rm get-docker.sh
                    sudo usermod -aG docker $USER
                    echo "Docker installed. Please restart your terminal session and re-run this script."
                    exit 0
                elif [[ "$OSTYPE" == "darwin"* ]]; then
                    echo "Please install Docker Desktop for Mac from https://www.docker.com/products/docker-desktop/"
                    exit 1
                else
                    echo "Automatic installation not supported for this OS."
                    exit 1
                fi
                ;;
            * ) exit 1;;
        esac
    fi
}

# Setup Docker
check_docker

# Skip starting containers if they already exist
if docker ps -a --format '{{.Names}}' | grep -qw pg_prod; then
    echo "Container pg_prod already exists. Skipping creation."
    SKIP_PG_PROD=true
else
    SKIP_PG_PROD=false
fi

# Check if API server container already exists
if docker ps -a --format '{{.Names}}' | grep -qw fno_api_server; then
    echo "Container fno_api_server already exists. Skipping creation."
    SKIP_API_SERVER=true
else
    SKIP_API_SERVER=false
fi

# Pull PostgreSQL image
docker pull postgres:15

# Create Docker networks if not exist
docker network inspect fno_net &>/dev/null || docker network create fno_net

# Build custom Postgres image with Python, build_mock, and init_postgres
cat > Dockerfile.pg <<EOF
FROM postgres:15
USER root
RUN apt-get update && apt-get install -y python3 python3-pip libpq-dev python3-dev python3-psycopg2
WORKDIR /docker-entrypoint-initdb.d/
COPY src/build_mock.py .
COPY src/init_postgres.py .
COPY src/ ./src/
RUN python3 build_mock.py
USER postgres
EOF

docker build -f Dockerfile.pg -t fno_pg_custom .

# Build and run PostgreSQL containers if not skipped
if [ "$SKIP_PG_PROD" = false ]; then
    docker run -d --name pg_prod \
        --network fno_net \
        -e POSTGRES_PASSWORD=prodpassword \
        -e POSTGRES_USER=produser \
        -e POSTGRES_DB=proddb \
        -p 5465:5432 \
        fno_pg_custom
    # Wait for DB to be ready
    echo "Waiting for PostgreSQL to be ready..."
    until docker exec pg_prod pg_isready -U produser; do sleep 1; done
    # Run the data import script inside the container
    docker exec pg_prod bash -c "python3 /docker-entrypoint-initdb.d/init_postgres.py"
fi

# Build the API server Docker image if not skipped
if [ "$SKIP_API_SERVER" = false ]; then
    cat > Dockerfile.api <<EOF
FROM node:18
WORKDIR /app
COPY src/ .
RUN apt-get update && apt-get install -y python3 && \\
    python3 build_mock.py
RUN npm init -y && npm install express pg
EXPOSE 3000
CMD ["node", "fno_data__server"]
EOF

    docker build -f Dockerfile.api -t fno_api_server .
fi

# Run the API server container if not skipped
if [ "$SKIP_API_SERVER" = false ]; then
    docker run -d --name fno_api_server \
        --network fno_net \
        -p 3000:3000 \
        fno_api_server
fi
# Create the python virtual environment
if [ ! -d ".venv" ]; then
    echo "Creating Python virtual environment..."
    python3 -m venv .venv
    echo "To activate the virtual environment, run: source .venv/bin/activate"
else
    echo "Python virtual environment already exists."
fi

echo ""

echo "Please run the following commands to set up your environment:"
echo "1. Activate the virtual environment: \033[1;33msource .venv/bin/activate\033[0m"
echo "2. Install dependencies: \033[1;33mpip3 install -r requirements-dev.txt\033[0m"
echo "3. Enter the dbt directory: \033[1;33mcd dbt\033[0m"
echo ""
echo "TLDR: `source .venv/bin/activate && pip3 install -r requirements-dev.txt && cd dbt`"


echo ""

echo "Setup complete. PostgreSQL (prod:5465) and API server (3000) are running."
