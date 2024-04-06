# Use a lightweight Python base image:tag
FROM python:3.11-slim

# Set a working directory within the container
WORKDIR /app

# create the appuser
RUN useradd -m appuser

# change the owner of current dir to appuser
RUN chown appuser .

# now we can change the user
USER appuser

# Copy the requirements.txt file
COPY requirements.txt ./

# Install Python dependencies using pip
RUN pip install -r requirements.txt

# Add a new layer for a specific dependency
# RUN pip install pandas  # This creates a new layer

# Copy the application code
COPY app.py .

# Expose the port where the Flask application runs (typically 5000)
EXPOSE 5000

# Set the default command to run the Flask application
CMD ["python", "app.py"]
