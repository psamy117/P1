const express = require('express');
const http = require('http');
const { Server } = require('socket.io');
const path = require('path');
const { v4: uuidv4 } = require('uuid');

const app = express();
const server = http.createServer(app);
const io = new Server(server);

/* ── Static files ─────────────────────────────────────────────────────── */
app.use(express.static(path.join(__dirname, '../client')));
app.use('/shadow', express.static(path.join(__dirname, '../client/shadow')));

/* ═══════════════════════════════════════════════════════════════════════
   THE SHADOW – real-time namespace
═══════════════════════════════════════════════════════════════════════ */
const shadowIO = io.of('/shadow');
const taskMessages = new Map();   // taskId → Message[]
const taskStatuses  = new Map();  // taskId → status string
const taskTimers    = new Map();  // taskId → timer refs

const MEERA_REPLIES = [
  "I'm with your father now, he's stable and smiling 😊",
  "Yes — uploading the prescription & bill now.",
  "Doctor says he's doing much better today. Don't worry!",
  "I've noted everything the doctor said. Sharing details now.",
  "Just sent you a photo from the ward 📸",
  "Report collected ✅ I'll share it in the chat right away.",
  "On my way to collect the prescription from the pharmacy.",
  "Everything is taken care of. Task almost done!",
];

const STATUS_STEPS = ['accepted', 'en_route', 'on_site'];
const STATUS_DELAYS = [0, 10000, 22000]; // ms after joining

function startTaskSimulation(taskId) {
  if (taskStatuses.has(taskId)) return;
  taskStatuses.set(taskId, 'pending');
  const timers = [];

  STATUS_STEPS.forEach((status, i) => {
    const t = setTimeout(() => {
      taskStatuses.set(taskId, status);
      shadowIO.to(taskId).emit('task_status', {
        status,
        timestamp: Date.now(),
        label: { accepted: 'Accepted', en_route: 'En route', on_site: 'On site — with your father now' }[status],
      });
      // Inject a system chat message at key milestones
      const sysMsgs = {
        accepted: { sender: 'shadow', text: "Hi! I'm Meera. I've accepted your task and am getting ready. 🙏" },
        en_route: { sender: 'shadow', text: "I'm on my way to Apollo Hospital now. ETA ~15 min." },
        on_site:  { sender: 'shadow', text: "I'm with your father now, he's stable and smiling 😊" },
      };
      if (sysMsgs[status]) {
        const msg = { id: uuidv4(), ...sysMsgs[status], timestamp: Date.now() };
        if (!taskMessages.has(taskId)) taskMessages.set(taskId, []);
        taskMessages.get(taskId).push(msg);
        shadowIO.to(taskId).emit('message', msg);
      }
    }, STATUS_DELAYS[i]);
    timers.push(t);
  });
  taskTimers.set(taskId, timers);
}

/* Location simulation – moves from start to hospital over ~30 seconds */
const LOC_PATH = [
  { x: 18, y: 72 }, { x: 22, y: 68 }, { x: 28, y: 62 },
  { x: 35, y: 55 }, { x: 40, y: 48 }, { x: 46, y: 42 },
  { x: 52, y: 38 }, { x: 57, y: 33 }, { x: 60, y: 28 },
];
const locIntervals = new Map();

function startLocationSimulation(taskId) {
  if (locIntervals.has(taskId)) return;
  let step = 0;
  const iv = setInterval(() => {
    if (step >= LOC_PATH.length) { clearInterval(iv); return; }
    shadowIO.to(taskId).emit('location', { ...LOC_PATH[step], step, total: LOC_PATH.length });
    step++;
  }, 3500);
  locIntervals.set(taskId, iv);
}

shadowIO.on('connection', (socket) => {
  socket.on('join_task', (taskId) => {
    socket.join(taskId);
    socket.emit('history', taskMessages.get(taskId) || []);
    socket.emit('task_status', {
      status: taskStatuses.get(taskId) || 'pending',
      timestamp: Date.now(),
    });
    startTaskSimulation(taskId);
    startLocationSimulation(taskId);
  });

  socket.on('message', ({ taskId, text, sender }) => {
    if (!text?.trim()) return;
    const msg = { id: uuidv4(), sender, text: text.trim(), timestamp: Date.now() };
    if (!taskMessages.has(taskId)) taskMessages.set(taskId, []);
    taskMessages.get(taskId).push(msg);
    shadowIO.to(taskId).emit('message', msg);

    if (sender === 'user') {
      setTimeout(() => {
        const reply = {
          id: uuidv4(), sender: 'shadow',
          text: MEERA_REPLIES[Math.floor(Math.random() * MEERA_REPLIES.length)],
          timestamp: Date.now(),
        };
        taskMessages.get(taskId).push(reply);
        shadowIO.to(taskId).emit('message', reply);
      }, 1500 + Math.random() * 1500);
    }
  });

  socket.on('complete_task', (taskId) => {
    taskStatuses.set(taskId, 'completed');
    shadowIO.to(taskId).emit('task_status', { status: 'completed', timestamp: Date.now() });
    (taskTimers.get(taskId) || []).forEach(clearTimeout);
    const iv = locIntervals.get(taskId);
    if (iv) clearInterval(iv);
  });
});

/* ═══════════════════════════════════════════════════════════════════════
   CHAT APP – original namespace (default /)
═══════════════════════════════════════════════════════════════════════ */
const users    = new Map();
const rooms    = new Map();
const messages = new Map();

function getRoomMessages(room) { return messages.get(room) || []; }
function addMessage(room, msg) {
  if (!messages.has(room)) messages.set(room, []);
  const list = messages.get(room);
  list.push(msg);
  if (list.length > 100) list.shift();
}
function getRoomUsers(room) {
  return [...(rooms.get(room) || new Set())].map(id => users.get(id)).filter(Boolean);
}

io.on('connection', (socket) => {
  socket.on('join', ({ username, room }) => {
    username = username.trim().slice(0, 30);
    room = (room || '').trim().slice(0, 50) || 'General';
    const prev = users.get(socket.id);
    if (prev) {
      socket.leave(prev.room);
      const s = rooms.get(prev.room); if (s) s.delete(socket.id);
      io.to(prev.room).emit('user_left', { username: prev.username, users: getRoomUsers(prev.room) });
    }
    users.set(socket.id, { id: socket.id, username, room });
    if (!rooms.has(room)) rooms.set(room, new Set());
    rooms.get(room).add(socket.id);
    socket.join(room);
    socket.emit('history', getRoomMessages(room));
    io.to(room).emit('user_joined', { username, users: getRoomUsers(room) });
    const sys = { id: uuidv4(), system: true, text: `${username} joined the room`, timestamp: Date.now() };
    addMessage(room, sys);
    io.to(room).emit('message', sys);
  });

  socket.on('send_message', ({ text }) => {
    const user = users.get(socket.id);
    if (!user || !text?.trim()) return;
    const msg = { id: uuidv4(), username: user.username, text: text.trim().slice(0, 1000), timestamp: Date.now() };
    addMessage(user.room, msg);
    io.to(user.room).emit('message', msg);
  });

  socket.on('typing', (isTyping) => {
    const user = users.get(socket.id);
    if (user) socket.to(user.room).emit('typing', { username: user.username, isTyping });
  });

  socket.on('get_rooms', () => socket.emit('rooms_list', [...rooms.keys()]));

  socket.on('disconnect', () => {
    const user = users.get(socket.id);
    if (!user) return;
    const { username, room } = user;
    users.delete(socket.id);
    const s = rooms.get(room); if (s) { s.delete(socket.id); if (!s.size) rooms.delete(room); }
    const sys = { id: uuidv4(), system: true, text: `${username} left the room`, timestamp: Date.now() };
    addMessage(room, sys);
    io.to(room).emit('message', sys);
    io.to(room).emit('user_left', { username, users: getRoomUsers(room) });
  });
});

const PORT = process.env.PORT || 3000;
server.listen(PORT, () => console.log(`Server running → http://localhost:${PORT}/shadow`));
