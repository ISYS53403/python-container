# Basic Containerized Python Application

This repository hosts all components needed to build a containerized API with Python and Flask.

## Prerequisites

- Rancher Desktop, or any tool with the Docker CLI.
- (Optional) Python 3.11+ for testing

## Build Instructions

```bash
docker build -t my-flask-app .
```

## Run the application

```bash
docker run -p 5000:5000 my-flask-app
```
