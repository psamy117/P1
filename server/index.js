const express = require('express');
const http = require('http');
const { Server } = require('socket.io');
const path = require('path');
const { v4: uuidv4 } = require('uuid');

const app = express();
const server = http.createServer(app);
const io = new Server(server);

app.use(express.static(path.join(__dirname, '../client')));

// In-memory store
const users = new Map();       // socketId -> { id, username, room }
const rooms = new Map();       // roomName -> Set of socketIds
const messages = new Map();    // roomName -> [{ id, username, text, timestamp }]

function getRoomMessages(room) {
  return messages.get(room) || [];
}

function addMessage(room, msg) {
  if (!messages.has(room)) messages.set(room, []);
  const list = messages.get(room);
  list.push(msg);
  // Keep last 100 messages per room
  if (list.length > 100) list.shift();
}

function getRoomUsers(room) {
  const ids = rooms.get(room) || new Set();
  return [...ids].map(id => users.get(id)).filter(Boolean);
}

io.on('connection', (socket) => {
  // Join a room
  socket.on('join', ({ username, room }) => {
    username = username.trim().slice(0, 30);
    room = room.trim().slice(0, 50) || 'General';

    // Leave previous room if any
    const prev = users.get(socket.id);
    if (prev) {
      socket.leave(prev.room);
      const prevSet = rooms.get(prev.room);
      if (prevSet) prevSet.delete(socket.id);
      io.to(prev.room).emit('user_left', { username: prev.username, users: getRoomUsers(prev.room) });
    }

    users.set(socket.id, { id: socket.id, username, room });
    if (!rooms.has(room)) rooms.set(room, new Set());
    rooms.get(room).add(socket.id);
    socket.join(room);

    // Send message history
    socket.emit('history', getRoomMessages(room));

    // Notify room
    io.to(room).emit('user_joined', { username, users: getRoomUsers(room) });

    const sysMsg = { id: uuidv4(), system: true, text: `${username} joined the room`, timestamp: Date.now() };
    addMessage(room, sysMsg);
    io.to(room).emit('message', sysMsg);
  });

  // Send a message
  socket.on('send_message', ({ text }) => {
    const user = users.get(socket.id);
    if (!user || !text || !text.trim()) return;
    const msg = {
      id: uuidv4(),
      username: user.username,
      text: text.trim().slice(0, 1000),
      timestamp: Date.now(),
    };
    addMessage(user.room, msg);
    io.to(user.room).emit('message', msg);
  });

  // Typing indicator
  socket.on('typing', (isTyping) => {
    const user = users.get(socket.id);
    if (!user) return;
    socket.to(user.room).emit('typing', { username: user.username, isTyping });
  });

  // List available rooms
  socket.on('get_rooms', () => {
    socket.emit('rooms_list', [...rooms.keys()]);
  });

  socket.on('disconnect', () => {
    const user = users.get(socket.id);
    if (!user) return;
    const { username, room } = user;
    users.delete(socket.id);
    const roomSet = rooms.get(room);
    if (roomSet) {
      roomSet.delete(socket.id);
      if (roomSet.size === 0) rooms.delete(room);
    }
    const sysMsg = { id: uuidv4(), system: true, text: `${username} left the room`, timestamp: Date.now() };
    addMessage(room, sysMsg);
    io.to(room).emit('message', sysMsg);
    io.to(room).emit('user_left', { username, users: getRoomUsers(room) });
  });
});

const PORT = process.env.PORT || 3000;
server.listen(PORT, () => console.log(`Server running on http://localhost:${PORT}`));
