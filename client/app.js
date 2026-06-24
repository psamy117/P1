const socket = io();

// ── State ──────────────────────────────────────────────────────────────────
let myUsername = '';
let myRoom = '';
let typingTimer = null;
let isTyping = false;
const typingUsers = new Set();

// ── DOM refs ───────────────────────────────────────────────────────────────
const loginScreen   = document.getElementById('login-screen');
const chatScreen    = document.getElementById('chat-screen');
const usernameInput = document.getElementById('username-input');
const roomInput     = document.getElementById('room-input');
const joinBtn       = document.getElementById('join-btn');
const loginError    = document.getElementById('login-error');
const roomsBtn      = document.getElementById('rooms-btn');
const roomsDropdown = document.getElementById('rooms-dropdown');
const leaveBtn      = document.getElementById('leave-btn');
const messagesEl    = document.getElementById('messages');
const messageInput  = document.getElementById('message-input');
const sendBtn       = document.getElementById('send-btn');
const membersList   = document.getElementById('members-list');
const memberCount   = document.getElementById('member-count');
const headerMemberCount = document.getElementById('header-member-count');
const currentRoomName   = document.getElementById('current-room-name');
const headerRoomName    = document.getElementById('header-room-name');
const typingIndicator   = document.getElementById('typing-indicator');
const sidebarToggle     = document.getElementById('sidebar-toggle');
const sidebar           = document.querySelector('.sidebar');

// ── Avatar colors ──────────────────────────────────────────────────────────
const COLORS = ['#6366f1','#8b5cf6','#ec4899','#f59e0b','#10b981','#3b82f6','#ef4444','#14b8a6'];
function colorFor(name) {
  let h = 0;
  for (const c of name) h = (h * 31 + c.charCodeAt(0)) & 0xffffffff;
  return COLORS[Math.abs(h) % COLORS.length];
}
function initials(name) { return name.slice(0, 2).toUpperCase(); }

// ── Login ──────────────────────────────────────────────────────────────────
joinBtn.addEventListener('click', doJoin);
[usernameInput, roomInput].forEach(el => el.addEventListener('keydown', e => { if (e.key === 'Enter') doJoin(); }));

function doJoin() {
  const username = usernameInput.value.trim();
  if (!username) { showError('Please enter your name.'); return; }
  const room = roomInput.value.trim() || 'General';
  myUsername = username;
  myRoom = room;
  socket.emit('join', { username, room });
  loginError.classList.add('hidden');
}

function showError(msg) {
  loginError.textContent = msg;
  loginError.classList.remove('hidden');
}

// Rooms browser
roomsBtn.addEventListener('click', () => {
  socket.emit('get_rooms');
  roomsDropdown.classList.toggle('hidden');
});

document.addEventListener('click', e => {
  if (!roomsDropdown.contains(e.target) && e.target !== roomsBtn) {
    roomsDropdown.classList.add('hidden');
  }
});

socket.on('rooms_list', (list) => {
  roomsDropdown.innerHTML = '';
  if (list.length === 0) {
    roomsDropdown.innerHTML = '<div class="no-rooms">No active rooms yet.</div>';
  } else {
    list.forEach(r => {
      const item = document.createElement('div');
      item.className = 'room-item';
      item.textContent = '#' + r;
      item.addEventListener('click', () => {
        roomInput.value = r;
        roomsDropdown.classList.add('hidden');
      });
      roomsDropdown.appendChild(item);
    });
  }
  roomsDropdown.classList.remove('hidden');
});

// ── Chat screen ────────────────────────────────────────────────────────────
function enterChat() {
  loginScreen.classList.remove('active');
  chatScreen.classList.add('active');
  const label = '#' + myRoom.toLowerCase();
  currentRoomName.textContent = label;
  headerRoomName.textContent  = label;
  messageInput.focus();
}

leaveBtn.addEventListener('click', () => {
  location.reload();
});

// ── Messages ───────────────────────────────────────────────────────────────
let lastDate = null;

function formatTime(ts) {
  return new Date(ts).toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' });
}
function formatDate(ts) {
  const d = new Date(ts);
  const today = new Date();
  if (d.toDateString() === today.toDateString()) return 'Today';
  const yesterday = new Date(today);
  yesterday.setDate(today.getDate() - 1);
  if (d.toDateString() === yesterday.toDateString()) return 'Yesterday';
  return d.toLocaleDateString([], { month: 'short', day: 'numeric', year: 'numeric' });
}

function appendMessage(msg, prepend = false) {
  if (!msg.system) {
    const date = formatDate(msg.timestamp);
    if (date !== lastDate) {
      const div = document.createElement('div');
      div.className = 'date-divider';
      div.textContent = date;
      if (prepend) messagesEl.prepend(div);
      else messagesEl.appendChild(div);
      lastDate = date;
    }
  }

  const wrap = document.createElement('div');
  wrap.className = 'msg';

  if (msg.system) {
    wrap.classList.add('system');
    const bubble = document.createElement('div');
    bubble.className = 'msg-bubble';
    bubble.textContent = msg.text;
    wrap.appendChild(bubble);
  } else {
    const isOwn = msg.username === myUsername;
    wrap.classList.add(isOwn ? 'own' : 'other');

    if (!isOwn) {
      const meta = document.createElement('div');
      meta.className = 'msg-meta';
      const sender = document.createElement('span');
      sender.className = 'sender';
      sender.textContent = msg.username;
      sender.style.color = colorFor(msg.username);
      const time = document.createElement('span');
      time.className = 'time';
      time.textContent = formatTime(msg.timestamp);
      meta.append(sender, time);
      wrap.appendChild(meta);
    } else {
      const meta = document.createElement('div');
      meta.className = 'msg-meta';
      const time = document.createElement('span');
      time.className = 'time';
      time.textContent = formatTime(msg.timestamp);
      meta.appendChild(time);
      wrap.appendChild(meta);
    }

    const bubble = document.createElement('div');
    bubble.className = 'msg-bubble';
    bubble.textContent = msg.text;
    wrap.appendChild(bubble);
  }

  if (prepend) messagesEl.prepend(wrap);
  else messagesEl.appendChild(wrap);
}

function scrollToBottom() {
  messagesEl.scrollTop = messagesEl.scrollHeight;
}

// ── Members ────────────────────────────────────────────────────────────────
function updateMembers(users) {
  membersList.innerHTML = '';
  users.forEach(u => {
    const li = document.createElement('li');
    if (u.username === myUsername) li.classList.add('me');
    const avatar = document.createElement('div');
    avatar.className = 'avatar';
    avatar.style.background = colorFor(u.username);
    avatar.textContent = initials(u.username);
    const name = document.createElement('span');
    name.className = 'name';
    name.textContent = u.username;
    li.append(avatar, name);
    membersList.appendChild(li);
  });
  memberCount.textContent = users.length;
  headerMemberCount.textContent = `${users.length} member${users.length !== 1 ? 's' : ''}`;
}

// ── Typing ─────────────────────────────────────────────────────────────────
function updateTypingIndicator() {
  const others = [...typingUsers].filter(u => u !== myUsername);
  if (others.length === 0) {
    typingIndicator.textContent = '';
    typingIndicator.classList.add('hidden');
  } else {
    const names = others.length <= 2 ? others.join(' and ') : `${others[0]} and ${others.length - 1} others`;
    typingIndicator.textContent = `${names} ${others.length === 1 ? 'is' : 'are'} typing...`;
    typingIndicator.classList.remove('hidden');
  }
}

messageInput.addEventListener('input', () => {
  if (!isTyping) {
    isTyping = true;
    socket.emit('typing', true);
  }
  clearTimeout(typingTimer);
  typingTimer = setTimeout(() => {
    isTyping = false;
    socket.emit('typing', false);
  }, 1500);
});

// ── Send ───────────────────────────────────────────────────────────────────
function sendMessage() {
  const text = messageInput.value.trim();
  if (!text) return;
  socket.emit('send_message', { text });
  messageInput.value = '';
  clearTimeout(typingTimer);
  if (isTyping) { isTyping = false; socket.emit('typing', false); }
  messageInput.focus();
}

sendBtn.addEventListener('click', sendMessage);
messageInput.addEventListener('keydown', e => { if (e.key === 'Enter' && !e.shiftKey) { e.preventDefault(); sendMessage(); } });

// ── Socket events ──────────────────────────────────────────────────────────
socket.on('history', (msgs) => {
  messagesEl.innerHTML = '';
  lastDate = null;
  msgs.forEach(m => appendMessage(m));
  enterChat();
  scrollToBottom();
});

socket.on('message', (msg) => {
  appendMessage(msg);
  scrollToBottom();
});

socket.on('user_joined', ({ users }) => updateMembers(users));
socket.on('user_left',   ({ users }) => updateMembers(users));

socket.on('typing', ({ username, isTyping: t }) => {
  if (t) typingUsers.add(username);
  else   typingUsers.delete(username);
  updateTypingIndicator();
});

socket.on('connect_error', () => showError('Connection failed. Please refresh.'));

// ── Sidebar toggle (mobile) ────────────────────────────────────────────────
sidebarToggle.addEventListener('click', () => sidebar.classList.toggle('open'));
document.addEventListener('click', e => {
  if (sidebar.classList.contains('open') && !sidebar.contains(e.target) && e.target !== sidebarToggle) {
    sidebar.classList.remove('open');
  }
});
