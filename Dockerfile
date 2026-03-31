FROM python:3.11-slim

WORKDIR /app

# Install Azure CLI for DefaultAzureCredential (dev/test; use managed identity in production)
RUN apt-get update && \
    apt-get install -y --no-install-recommends curl apt-transport-https gnupg && \
    curl -sL https://aka.ms/InstallAzureCLIDeb | bash && \
    apt-get clean && rm -rf /var/lib/apt/lists/*

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY . .

ENV PYTHONPATH=/app/src

EXPOSE 8000

CMD ["chainlit", "run", "src/web/app.py", "--host", "0.0.0.0", "--port", "8000"]
