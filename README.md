# Basic Containerized Python Application

This repository hosts all components needed to build a containerized API with Python and Flask.

## Prerequisites

- Docker CLI installed
- (Optional) Python 3.11+ for testing

## Build Instructions

```bash
docker build -t my-flask-app .
```

## Run the application

```bash
docker run -p 5000:5000 my-flask-app
```
