FROM python:3.12-slim
WORKDIR /app
COPY load.py .
ENV SCENARIO=steady \
    REQUESTS_PER_SECOND=2.0
CMD ["python", "load.py"]
