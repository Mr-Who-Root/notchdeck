// NotchDeck's Now Playing helper. Run by the app as
//
//     /usr/bin/osascript -l JavaScript notchdeck-nowplaying.js
//
// Since macOS 15.4 the MediaRemote framework only answers "what is playing"
// for Apple-signed processes, so the app cannot ask it in-process. osascript
// is Apple's own, and its JavaScript bridge can load the framework, read the
// system's now-playing item and send it transport commands.
//
// Protocol, one JSON object per line:
//   stdout  {"type":"state", ...}    whenever the item or its playback changes
//           {"type":"artwork", ...}  when the artwork changes (base64, or null)
//           {"type":"unavailable"}   MediaRemote could not be loaded
//   stdin   play | pause | toggle | next | previous | seek <seconds>
//
// The helper exits when stdin closes, so it never outlives the app.
ObjC.import('Foundation');

function run() {
  const out = $.NSFileHandle.fileHandleWithStandardOutput;
  const emit = (obj) => {
    try {
      out.writeData($(JSON.stringify(obj) + '\n').dataUsingEncoding($.NSUTF8StringEncoding));
    } catch (e) {
      // The app went away mid-write; the read loop below notices EOF.
    }
  };

  const bundle = $.NSBundle.bundleWithPath('/System/Library/PrivateFrameworks/MediaRemote.framework/');
  if (!bundle || !bundle.load) { emit({ type: 'unavailable' }); return; }
  const Request = $.NSClassFromString('MRNowPlayingRequest');
  if (!Request || (Request.isNil && Request.isNil())) { emit({ type: 'unavailable' }); return; }

  let canSend = true;
  try {
    ObjC.bindFunction('MRMediaRemoteSendCommand', ['bool', ['int', 'id']]);
    ObjC.bindFunction('MRMediaRemoteSetElapsedTime', ['void', ['double']]);
  } catch (e) {
    canSend = false;
  }

  // MRMediaRemoteCommand values.
  const COMMANDS = { play: 0, pause: 1, toggle: 2, next: 4, previous: 5 };

  let alive = true;
  let pollSoon = true;

  const handle = (line) => {
    const parts = line.trim().split(/\s+/);
    const verb = parts[0];
    if (!verb || !canSend) return;
    try {
      if (verb === 'seek') {
        const seconds = parseFloat(parts[1]);
        if (isFinite(seconds) && seconds >= 0) $.MRMediaRemoteSetElapsedTime(seconds);
      } else if (verb in COMMANDS) {
        $.MRMediaRemoteSendCommand(COMMANDS[verb], $());
      }
    } catch (e) {
      // A command the player does not support is simply not carried out.
    }
    pollSoon = true;
  };

  let pending = '';
  ObjC.registerSubclass({
    name: 'NotchDeckNowPlayingReader',
    methods: {
      'onData:': {
        types: ['void', ['id']],
        implementation: function (note) {
          const data = note.userInfo.objectForKey($.NSFileHandleNotificationDataItem);
          if (!data || data.length == 0) { alive = false; return; }
          pending += ObjC.unwrap($.NSString.alloc.initWithDataEncoding(data, $.NSUTF8StringEncoding)) || '';
          let newline;
          while ((newline = pending.indexOf('\n')) >= 0) {
            handle(pending.slice(0, newline));
            pending = pending.slice(newline + 1);
          }
          note.object.readInBackgroundAndNotify;
        }
      }
    }
  });
  const reader = $.NotchDeckNowPlayingReader.alloc.init;
  const stdin = $.NSFileHandle.fileHandleWithStandardInput;
  $.NSNotificationCenter.defaultCenter.addObserverSelectorNameObject(
    reader, 'onData:', $.NSFileHandleReadCompletionNotification, stdin);
  stdin.readInBackgroundAndNotify;

  const isNil = (o) => o === undefined || o === null || (o.isNil && o.isNil());
  const str = (o) => { if (isNil(o)) return null; const v = ObjC.unwrap(o); return typeof v === 'string' && v.length ? v : null; };
  const num = (o) => { if (isNil(o)) return null; const v = ObjC.unwrap(o); return typeof v === 'number' && isFinite(v) ? v : null; };
  const key = (name) => 'kMRMediaRemoteNowPlayingInfo' + name;

  let lastState = '';
  let lastArtworkKey = null;

  const poll = () => {
    let item = null, info = null, path = null;
    try { item = Request.localNowPlayingItem; } catch (e) {}
    try { if (!isNil(item)) info = item.nowPlayingInfo; } catch (e) {}
    try { path = Request.localNowPlayingPlayerPath; } catch (e) {}

    const state = { type: 'state', present: false };
    if (!isNil(info)) {
      const get = (name) => info.valueForKey(key(name));
      state.title = str(get('Title'));
      state.artist = str(get('Artist'));
      state.album = str(get('Album'));
      state.duration = num(get('Duration'));
      state.elapsed = num(get('ElapsedTime'));
      state.rate = num(get('PlaybackRate'));
      const stamp = get('Timestamp');
      state.timestamp = isNil(stamp) ? null : stamp.timeIntervalSince1970;
      state.itemID = str(get('ContentItemIdentifier'));
      state.present = !!(state.title || state.artist);
    }
    try { state.playing = !!Request.localIsPlaying; } catch (e) { state.playing = (state.rate || 0) > 0; }
    try {
      if (!isNil(path) && !isNil(path.client)) {
        state.bundleID = str(path.client.bundleIdentifier);
        state.appName = str(path.client.displayName);
      }
    } catch (e) {}
    state.canSend = canSend;

    const encoded = JSON.stringify(state);
    if (encoded !== lastState) {
      lastState = encoded;
      emit(state);
    }

    // Artwork travels separately, and only when it changes: it is the one
    // large thing here, and a seek or a pause must not resend it.
    let artwork = null, mime = null;
    if (!isNil(info)) {
      const data = info.valueForKey(key('ArtworkData'));
      if (!isNil(data) && data.length > 0) {
        artwork = data;
        mime = str(info.valueForKey(key('ArtworkMIMEType')));
      }
    }
    const artworkKey = artwork
      ? [state.itemID, state.title, state.artist, state.album, artwork.length].join('|')
      : '';
    if (artworkKey !== lastArtworkKey) {
      lastArtworkKey = artworkKey;
      emit({ type: 'artwork', mime: mime,
             data: artwork ? ObjC.unwrap(artwork.base64EncodedStringWithOptions(0)) : null });
    }
  };

  let ticks = 0;
  while (alive) {
    $.NSRunLoop.currentRunLoop.runUntilDate($.NSDate.dateWithTimeIntervalSinceNow(0.25));
    ticks++;
    if (pollSoon || ticks % 4 === 0) {
      // Right after a command the player has rarely caught up yet; look again
      // on the next tick as well.
      const again = pollSoon;
      pollSoon = false;
      try { poll(); } catch (e) {}
      if (again) ticks = 3;
    }
  }
}
