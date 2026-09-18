# All-in-one zero-conf local AI

This project is a wrapper of the best open-source AI tools available out there.

## Features

Install AI models locally and access them through a web API with an API key.

Chat with you local AI models through a web interface.

Generate customized install scripts for your local server or your VMs (Virtual Machine).

## Components

### AI Inference Engines

- Ollama
- vLLM

### Authentication

Some inference engines do not prodive authentication nor HTTPS so a reverse proxy wraps them to provide HTTPS and an API Key access.

### AI Model Provisioning

- llmfit

### Chat Interface Websites

- LibreChat

## Layers

The project is organized by layers of increasing complexity. The previous layer is wrapped by the next one. Each layer can be used without the next ones.

### Intall Scripts

Each component has an install script with some parameters to install and configure the component in one go.

A script generator helps you to generate parameterless install-and-configure scripts with fixed parameters.

### Snap Package

The snap package is wrapping everything in one package. Each install-and-configure script is reachable from the snap commands and each component commands is mirrored by the snap.

Extra commands :

- listing what is currently installed
- adding a new model in a inference engine, wrap it with the reverse proxy if needed and add it in the chat interface website

### Post-install script for VMs

Same as the install scripts but with the snap. One script with some parameters to install and configure the snap in one go and an generator script to generate some parameterless install-and-configure scripts with fixed parameters.
