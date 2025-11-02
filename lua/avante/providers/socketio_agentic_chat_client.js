#!/usr/bin/env node

/**
 * Socket.IO client for GitLab Duo Agentic Chat integration
 * 
 * This script connects to the GitLab LSP's HTTP server and handles
 * agentic chat workflow, forwarding events to stdout as JSON lines.
 * 
 * Usage:
 *   node socketio_agentic_chat_client.js <base_url> <csrf_token> <workflow_params_json>
 * 
 * Example:
 *   node socketio_agentic_chat_client.js \
 *     "http://127.0.0.1:12345/webview/agentic-duo-chat" \
 *     "csrf_token_abc" \
 *     '{"goal":"explain this","type":"chat","metadata":{"projectId":"123"}}'
 */

const io = require('socket.io-client');

// Parse command line arguments
const args = process.argv.slice(2);
if (args.length < 3) {
  console.error(JSON.stringify({
    type: 'error',
    message: 'Usage: node socketio_agentic_chat_client.js <base_url> <csrf_token> <workflow_params_json>'
  }));
  process.exit(1);
}

const [baseUrl, csrfToken, workflowParamsJson] = args;

// Parse workflow parameters
let workflowParams;
try {
  workflowParams = JSON.parse(workflowParamsJson);
} catch (e) {
  console.error(JSON.stringify({
    type: 'error',
    message: `Failed to parse workflow params: ${e.message}`
  }));
  process.exit(1);
}

// Log to stderr for debugging (stdout is reserved for JSON events)
const debug = (msg) => console.error(`[SocketIO-Chat] ${msg}`);

debug(`Connecting to ${baseUrl}`);
debug(`Workflow params: ${JSON.stringify(workflowParams)}`);
debug(`CSRF Token: ${csrfToken}`);

// Connect to Socket.IO server
// Extract server root from baseUrl (e.g., http://127.0.0.1:60087)
const serverRoot = baseUrl.match(/^(https?:\/\/[^\/]+)/)[1];
debug(`Server root: ${serverRoot}`);

// Socket.IO is at the root /socket.io/, not under webview paths
// The LSP checks that there's NO origin header and verifies CSRF token
const socket = io(serverRoot, {
  path: '/socket.io/',
  transports: ['polling', 'websocket'],
  extraHeaders: {
    '_csrf': csrfToken
  },
  reconnection: true,
  reconnectionDelay: 1000,
  reconnectionAttempts: 5,
  // Don't send origin header - LSP expects it to be undefined
  autoConnect: false
});

// Track workflow ID
let currentWorkflowId = null;

// Manually connect after setup
socket.connect();
debug('Initiating connection...');

// Connection events
socket.on('connect', () => {
  debug('Connected to Socket.IO server');
  
  // Send webviewReady first (required for agentic chat)
  socket.emit('webviewReady');
  debug('Sent webviewReady notification');
  
  // Send appReady notification
  socket.emit('appReady');
  debug('Sent appReady notification');
  
  // Start the workflow with the provided parameters
  socket.emit('startWorkflow', workflowParams);
  debug('Sent startWorkflow with params');
  
  // Notify Lua that connection is ready
  console.log(JSON.stringify({
    type: 'connected'
  }));
});

socket.on('connect_error', (error) => {
  debug(`Connection error: ${error.message}`);
  debug(`Error details: ${JSON.stringify(error)}`);
  debug(`Trying to connect to: ${serverRoot} with path: /socket.io/`);
  console.log(JSON.stringify({
    type: 'error',
    message: `Connection error: ${error.message}`,
    details: error.description || error.type || 'unknown'
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
socket.on('workflowStarted', (data) => {
  debug('Received workflowStarted event');
  currentWorkflowId = data.workflowId || data.workflow_id || data.id;
  debug(`Workflow started with ID: ${currentWorkflowId}`);
  console.log(JSON.stringify({
    type: 'workflowStarted',
    data
  }));
  
  // Subscribe to this workflow's events
  if (currentWorkflowId) {
    socket.emit('startSubscriptions', { workflowId: currentWorkflowId });
    debug(`Sent startSubscriptions for workflow ${currentWorkflowId}`);
  }
});

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

socket.on('workflowPreCreated', (workflowId) => {
  debug('Received workflowPreCreated event');
  console.log(JSON.stringify({
    type: 'workflowPreCreated',
    workflowId
  }));
});

// Generic catch-all for any other events
socket.onAny((eventName, ...args) => {
  if (!['workflowCheckpoint', 'workflowStatus', 'workflowGoal', 'workflowError', 'initialState', 'workflowStarted', 'workflowPreCreated'].includes(eventName)) {
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

debug('Socket.IO Agentic Chat client initialized, waiting for events...');
