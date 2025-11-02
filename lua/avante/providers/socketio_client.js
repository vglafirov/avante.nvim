#!/usr/bin/env node

/**
 * Socket.IO client for GitLab Duo workflow integration
 * 
 * This script connects to the GitLab LSP's HTTP server and subscribes to
 * workflow events, forwarding them to stdout as JSON lines.
 * 
 * Usage:
 *   node socketio_client.js <base_url> <workflow_id> <csrf_token>
 * 
 * Example:
 *   node socketio_client.js http://127.0.0.1:12345/webview/duo_workflow_panel workflow_123 csrf_token_abc
 */

const io = require('socket.io-client');

// Parse command line arguments
const args = process.argv.slice(2);
if (args.length < 3) {
  console.error(JSON.stringify({
    type: 'error',
    message: 'Usage: node socketio_client.js <base_url> <workflow_id> <csrf_token>'
  }));
  process.exit(1);
}

const [baseUrl, workflowId, csrfToken] = args;

// Log to stderr for debugging (stdout is reserved for JSON events)
const debug = (msg) => console.error(`[SocketIO] ${msg}`);

debug(`Connecting to ${baseUrl}`);
debug(`Workflow ID: ${workflowId}`);
debug(`CSRF Token: ${csrfToken}`);

// Connect to Socket.IO server
const socket = io(baseUrl, {
  transports: ['websocket', 'polling'],
  query: {
    _csrf: csrfToken
  },
  reconnection: true,
  reconnectionDelay: 1000,
  reconnectionAttempts: 5
});

// Connection events
socket.on('connect', () => {
  debug('Connected to Socket.IO server');
  
  // Send appReady notification
  socket.emit('appReady');
  debug('Sent appReady notification');
  
  // Start subscriptions for the workflow
  socket.emit('startSubscriptions', { workflowId });
  debug(`Sent startSubscriptions for workflow ${workflowId}`);
  
  // Notify Lua that connection is ready
  console.log(JSON.stringify({
    type: 'connected',
    workflowId
  }));
});

socket.on('connect_error', (error) => {
  debug(`Connection error: ${error.message}`);
  console.log(JSON.stringify({
    type: 'error',
    message: `Connection error: ${error.message}`
  }));
});

socket.on('disconnect', (reason) => {
  debug(`Disconnected: ${reason}`);
  console.log(JSON.stringify({
    type: 'disconnected',
    reason
  }));
});

// Listen for workflow events
socket.on('workflowCheckpoint', (data) => {
  debug('Received workflowCheckpoint event');
  console.log(JSON.stringify({
    type: 'workflowCheckpoint',
    data
  }));
});

socket.on('workflowStatus', (status) => {
  debug('Received workflowStatus event');
  console.log(JSON.stringify({
    type: 'workflowStatus',
    status
  }));
});

socket.on('workflowGoal', (goal) => {
  debug('Received workflowGoal event');
  console.log(JSON.stringify({
    type: 'workflowGoal',
    goal
  }));
});

socket.on('workflowError', (error) => {
  debug('Received workflowError event');
  console.log(JSON.stringify({
    type: 'workflowError',
    error
  }));
});

socket.on('initialState', (state) => {
  debug('Received initialState event');
  console.log(JSON.stringify({
    type: 'initialState',
    state
  }));
});

// Generic catch-all for any other events
socket.onAny((eventName, ...args) => {
  if (!['workflowCheckpoint', 'workflowStatus', 'workflowGoal', 'workflowError', 'initialState'].includes(eventName)) {
    debug(`Received unknown event: ${eventName}`);
    console.log(JSON.stringify({
      type: 'event',
      name: eventName,
      args
    }));
  }
});

// Handle graceful shutdown
process.on('SIGINT', () => {
  debug('Received SIGINT, closing connection');
  socket.close();
  process.exit(0);
});

process.on('SIGTERM', () => {
  debug('Received SIGTERM, closing connection');
  socket.close();
  process.exit(0);
});

debug('Socket.IO client initialized, waiting for events...');
