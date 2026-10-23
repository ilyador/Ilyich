#!/usr/bin/env python3
"""Loopback-only synthetic library for native UI tests. No account or photo data."""
import datetime
import functools
import hashlib
import http.server
import json
import math
import os
import shutil
import struct
import subprocess
import tempfile
import threading
import urllib.parse
import uuid
import zlib

OWNER = '00000000-0000-4000-8000-000000000001'
BUCKETS = [{'timeBucket': f'{2026-i//12:04d}-{12-i%12:02d}-01', 'count': 100} for i in range(240)]
PERSON = {'id': '00000000-0000-4000-8000-000000000002', 'name': 'Maya', 'isHidden': False, 'isFavorite': True}
# A long People shelf, for the session of the tests that scroll one.
MANY_PEOPLE_TOKEN = 'ui-test-many-people'
MANY_PEOPLE = [PERSON] + [{'id': f'00000000-0000-4000-8000-0000000001{n:02d}', 'name': f'Friend {n:02d}', 'isHidden': False, 'isFavorite': False}
                          for n in range(2, 61)]
ALBUM = {'id': '00000000-0000-4000-8000-000000000003', 'albumName': 'Coast', 'assetCount': 100, 'shared': False,
         'albumUsers': [], 'albumThumbnailAssetId': None, 'updatedAt': '2026-12-01T12:00:00Z'}
# A second album, so shelf rows can be put in another order. It is shared only by a link,
# which the server reports as shared.
HARBOR = {'id': '00000000-0000-4000-8000-000000000004', 'albumName': 'Harbor', 'assetCount': 12, 'shared': True,
          'hasSharedLink': True, 'albumUsers': [], 'albumThumbnailAssetId': None, 'updatedAt': '2026-11-02T12:00:00Z'}
HARBOR_LINK = {'id': '00000000-0000-4000-8000-000000000005', 'key': 'fixture-harbor', 'slug': None, 'type': 'ALBUM',
               'description': 'Harbor for family', 'expiresAt': None, 'allowDownload': True, 'allowUpload': False,
               'showMetadata': False, 'assets': [], 'album': HARBOR}

def is_video(index, date):
    # One clip in the newest month, so the viewer's video page can be exercised.
    return date == '2026-12-01' and index == 5

def asset(index, date='2026-12-01'):
    video = is_video(index, date)
    return {'id': str(uuid.uuid5(uuid.NAMESPACE_URL, date + str(index))), 'ownerId': OWNER,
            'type': 'VIDEO' if video else 'IMAGE', 'originalFileName': f'Test clip {index}.mp4' if video else f'Test landscape {index}.jpg',
            'fileCreatedAt': date+'T12:00:00Z', 'localDateTime': date+'T12:00:00Z',
            'width': 600, 'height': 400, 'isFavorite': False, 'isTrashed': False,
            'isEdited': False, 'isDeveloped': index % 7 == 0, 'visibility': 'timeline',
            'mediaRevision': 'fixture-1', 'duration': 5000 if video else None, 'exifInfo': {
                'city': 'Amsterdam', 'country': 'Netherlands', 'latitude': 52.3676, 'longitude': 4.9041,
                'make': 'Test', 'model': 'Fixture camera', 'description': 'Synthetic UI test image',
                'fileSizeInByte': 100000, 'iso': 100, 'fNumber': 4, 'focalLength': 35,
            }, 'people': [PERSON]}

def iso(value):
    return value.astimezone(datetime.timezone.utc).strftime('%Y-%m-%dT%H:%M:%S.000Z')

def memories():
    # Current-date windows keep the fixture valid whenever the UI test runs.
    now = datetime.datetime.now(datetime.timezone.utc)
    start = now.replace(hour=0, minute=0, second=0, microsecond=0)
    specs = [('00000000-0000-4000-8000-0000000000a1', 'Maya Memory One', '2024-06-01', range(0, 3)),
             ('00000000-0000-4000-8000-0000000000a2', 'Maya Memory Two', '2025-10-01', range(3, 5))]
    result = []
    for identifier, name, date, indexes in specs:
        at = datetime.datetime.fromisoformat(date).replace(tzinfo=datetime.timezone.utc)
        result.append({'id': identifier, 'type': 'on_this_day', 'ownerId': OWNER, 'isSaved': False,
                       'memoryAt': iso(at), 'showAt': iso(start), 'hideAt': iso(start + datetime.timedelta(days=1)),
                       'createdAt': iso(start), 'updatedAt': iso(start), 'seenAt': None,
                       'data': {'year': at.year, 'personId': PERSON['id'], 'personName': name},
                       'assets': [asset(i, date) for i in indexes]})
    return result

VIDEO_ID = asset(5)['id']
# Sign-in UI tests: any password signs in, and an email starting with "expired" gets a session the
# server then says has expired.
SESSION_TOKEN = 'ui-test-session'
EXPIRED_TOKEN = 'ui-test-expired'

@functools.lru_cache(maxsize=1)
def test_clip():
    # A short synthetic clip, so the viewer shows a real player. Made in memory; nothing is kept.
    ffmpeg = shutil.which('ffmpeg') or '/opt/homebrew/bin/ffmpeg'
    if not os.path.exists(ffmpeg): return None
    handle, path = tempfile.mkstemp(suffix='.mp4'); os.close(handle)
    try:
        subprocess.run([ffmpeg, '-loglevel', 'error', '-y', '-f', 'lavfi', '-i', 'testsrc=duration=4:size=320x240:rate=15',
                        '-pix_fmt', 'yuv420p', '-movflags', '+faststart', path], check=True, timeout=60)
        with open(path, 'rb') as clip: return clip.read()
    except (OSError, subprocess.SubprocessError):
        return None
    finally:
        os.remove(path)

def bucket(date, developed=False):
    # Lightroom's timeline holds only the developed photos: every seventh.
    indexes = [i for i in range(100) if not developed or i % 7 == 0]
    assets = [asset(i,date) for i in indexes]
    n = len(assets)
    return {key: [a.get(key) for a in assets] for key in ['id','ownerId','isFavorite','isTrashed','visibility','fileCreatedAt','duration','mediaRevision']} | {
        'ratio': [1.5]*n, 'isImage': [not is_video(i, date) for i in indexes], 'createdAt':[date+'T12:00:00Z']*n,
        # A real thumbhash, so cells draw a sketch before their thumbnail arrives.
        'localOffsetHours':[0]*n, 'thumbhash':['HIcNXIyGh4d/eHh5eIWHcEf3dQ==']*n, 'livePhotoVideoId':[None]*n,
    }

@functools.lru_cache(maxsize=1024)
def test_image(seed):
    # Distinct deterministic landscape-like tonal fields test recycling and glass contrast.
    n = hashlib.sha256(seed.encode()).digest()
    w,h=300,200
    rows=[]
    for y in range(h):
        row=bytearray([0])
        for x in range(w):
            horizon=90+int(20*math.sin(x/50+n[0]))
            if y<horizon: rgb=(60+n[1]//3,125+n[2]//3,min(255,175+n[3]//3))
            else: rgb=(35+n[4]//3,65+n[5]//3,40+n[6]//3)
            if (x-220)**2+(y-40)**2<300:rgb=(255,226,160)
            row.extend(rgb)
        rows.append(bytes(row))
    def chunk(kind, data): return struct.pack('!I',len(data))+kind+data+struct.pack('!I',zlib.crc32(kind+data)&0xffffffff)
    return b'\x89PNG\r\n\x1a\n'+chunk(b'IHDR',struct.pack('!2I5B',w,h,8,2,0,0,0))+chunk(b'IDAT',zlib.compress(b''.join(rows)))+chunk(b'IEND',b'')

# A mutable session's library (REBUILD_ROADMAP.md N2). A UI test that changes the library signs in
# with a token of its own, new each launch, and only that token's requests see its changes:
# every other token gets exactly the answers above, so the tests that share this server never
# see another test's changes. Asset, Trash and album changes are kept in memory.
MUTABLE_PREFIX = 'ui-test-mutable-'

class MutableLibrary:
    def __init__(self):
        self.lock = threading.Lock()
        self.trashed = set()
        self.deleted = set()
        self.visibility = {}
        self.favorite = {}
        # Albums made in the session, and the photos added to or removed from any album.
        self.created = {}
        self.added = {}
        self.removed = {}
        self.album_fields = {}

LIBRARIES = {}
LIBRARIES_LOCK = threading.Lock()

def mutable_library(token):
    if not token or not token.startswith(MUTABLE_PREFIX): return None
    with LIBRARIES_LOCK:
        return LIBRARIES.setdefault(token, MutableLibrary())

@functools.lru_cache(maxsize=1)
def asset_locations():
    # Each synthetic photo's month and index, by ID.
    return {asset(i, b['timeBucket'][:10])['id']: (b['timeBucket'][:10], i) for b in BUCKETS for i in range(100)}

def changed_dates(library):
    ids = library.trashed | library.deleted | set(library.visibility) | set(library.favorite)
    for members in list(library.added.values()) + list(library.removed.values()): ids |= members
    locations = asset_locations()
    return {locations[i][0] for i in ids if i in locations}

def stated(library, value):
    # The photo as the session's changes left it, or None once deleted for good.
    if value['id'] in library.deleted: return None
    value = dict(value)
    value['isTrashed'] = value['id'] in library.trashed
    value['visibility'] = library.visibility.get(value['id'], value['visibility'])
    value['isFavorite'] = library.favorite.get(value['id'], value['isFavorite'])
    return value

def in_album(library, album, identifier):
    if album in library.created: return identifier in library.added.get(album, set())
    return identifier not in library.removed.get(album, set())

def timeline_matches(library, value, q):
    if value['isTrashed'] != (q.get('isTrashed', [''])[0] == 'true'): return False
    visibility = q.get('visibility', [None])[0]
    if visibility:
        if value['visibility'] != visibility: return False
    elif value['visibility'] not in ('timeline', 'archive'): return False
    if q.get('isFavorite', [''])[0] == 'true' and not value['isFavorite']: return False
    album = q.get('albumId', [None])[0]
    return album is None or in_album(library, album, value['id'])

def mutable_bucket_assets(library, date, q, developed):
    indexes = [i for i in range(100) if not developed or i % 7 == 0]
    values = (stated(library, asset(i, date)) for i in indexes)
    return [value for value in values if value is not None and timeline_matches(library, value, q)]

def mutable_buckets(library, q, developed):
    # Months the session changed nothing in count as the shared fixture's, when their photos match.
    touched = changed_dates(library)
    album = q.get('albumId', [None])[0]
    untouched = len(mutable_bucket_assets(MutableLibrary(), BUCKETS[0]['timeBucket'][:10], q, developed)) if album not in library.created else 0
    result = []
    for b in BUCKETS:
        date = b['timeBucket'][:10]
        count = len(mutable_bucket_assets(library, date, q, developed)) if date in touched else untouched
        if count: result.append({'timeBucket': b['timeBucket'], 'count': count})
    return result

def mutable_bucket(library, date, q, developed):
    assets = mutable_bucket_assets(library, date, q, developed)
    n = len(assets)
    return {key: [a.get(key) for a in assets] for key in ['id','ownerId','isFavorite','isTrashed','visibility','fileCreatedAt','duration','mediaRevision']} | {
        'ratio': [1.5]*n, 'isImage': [a['type'] != 'VIDEO' for a in assets], 'createdAt':[date+'T12:00:00Z']*n,
        'localOffsetHours':[0]*n, 'thumbhash':['HIcNXIyGh4d/eHh5eIWHcEf3dQ==']*n, 'livePhotoVideoId':[None]*n,
    }

def mutable_asset(library, identifier):
    location = asset_locations().get(identifier)
    value = asset(location[1], location[0]) if location else asset(1) | {'id': identifier}
    return stated(library, value)

def mutable_albums(library):
    albums = [dict(ALBUM), dict(HARBOR)] + [dict(album) for album in library.created.values()]
    for album in albums:
        album.update(library.album_fields.get(album['id'], {}))
        if album['id'] in library.created: album['assetCount'] = len(library.added.get(album['id'], set()))
        else: album['assetCount'] = max(0, album['assetCount'] - len(library.removed.get(album['id'], set())))
    return albums

class FixtureHTTPServer(http.server.ThreadingHTTPServer):
    # API and media use independent URLSessions. Their concurrent connections
    # exceed socketserver's default backlog of five during a cold scrub.
    request_queue_size = 128
    daemon_threads = True

class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self,*args): pass
    def send(self,value,status=200):
        data=json.dumps(value).encode();self.send_response(status);self.send_header('Content-Type','application/json');self.send_header('Content-Length',str(len(data)));self.end_headers();self.wfile.write(data)
    def send_immich_error(self,status,message):
        # Immich stamps its own errors with a correlation ID, which tells them from a proxy's.
        data=json.dumps({'message':message,'error':'Unauthorized' if status==401 else 'Error','statusCode':status}).encode()
        self.send_response(status);self.send_header('Content-Type','application/json');self.send_header('X-Correlation-ID',str(uuid.uuid4()))
        self.send_header('Content-Length',str(len(data)));self.end_headers();self.wfile.write(data)
    def token(self):
        return self.headers.get('x-immich-user-token') or self.headers.get('Authorization','').removeprefix('Bearer ')
    def send_empty(self,status=204):
        self.send_response(status);self.send_header('Content-Length','0');self.end_headers()
    def read_body(self):
        size=int(self.headers.get('Content-Length','0'));return json.loads(self.rfile.read(size) or b'{}')
    def unsupported(self):
        # What the server answered before it took changes, for every session but a mutable one.
        self.send_error(http.HTTPStatus.NOT_IMPLEMENTED, "Unsupported method (%r)" % self.command)
    def do_GET(self):
        url=urllib.parse.urlsplit(self.path);path=url.path.removeprefix('/api');q=urllib.parse.parse_qs(url.query)
        library=mutable_library(self.token())
        if library is not None and self.mutable_get(library,path,q): return
        if path.startswith('/assets/') and path.endswith('/original'):
            # Deliberately stream slowly, over about 15 s, so the UI test can cancel a real in-flight
            # export. XCTest takes several seconds to find the cancel button; a 3 s stream finished
            # first, and the share sheet then covered the viewer.
            import time
            data=test_image(path)
            self.send_response(200);self.send_header('Content-Type','image/png');self.send_header('Content-Length',str(len(data)))
            self.send_header('Content-Disposition','attachment; filename="fixture-original.png"');self.end_headers()
            step=max(1,(len(data)+29)//30)
            try:
                for start in range(0,len(data),step):
                    self.wfile.write(data[start:start+step]);self.wfile.flush();time.sleep(0.5)
            except (BrokenPipeError,ConnectionResetError): pass
            return
        if path.endswith('/thumbnail'):
            data=test_image(path);self.send_response(200);self.send_header('Content-Type','image/png');self.send_header('Content-Length',str(len(data)));self.send_header('Cache-Control','max-age=3600');self.end_headers();self.wfile.write(data);return
        developed=q.get('isDeveloped',[''])[0]=='true'
        if path=='/timeline/buckets':return self.send([b|{'count':15} for b in BUCKETS] if developed else BUCKETS)
        if path=='/timeline/bucket':return self.send(bucket(q.get('timeBucket',['2026-12-01'])[0][:10], developed))
        if path.endswith('/video/playback'):
            data=test_clip()
            if data is None: self.send_response(404);self.end_headers();return
            # AVPlayer asks for byte ranges.
            start,end=0,len(data)-1
            ranged=self.headers.get('Range','')
            if ranged.startswith('bytes='):
                first,_,last=ranged[6:].partition('-')
                start=int(first) if first else 0
                end=min(int(last),len(data)-1) if last else len(data)-1
                self.send_response(206);self.send_header('Content-Range',f'bytes {start}-{end}/{len(data)}')
            else: self.send_response(200)
            self.send_header('Content-Type','video/mp4');self.send_header('Accept-Ranges','bytes');self.send_header('Content-Length',str(end-start+1));self.end_headers()
            try: self.wfile.write(data[start:end+1])
            except (BrokenPipeError,ConnectionResetError): pass
            return
        if path.startswith('/assets/'):
            if path.endswith('/ocr'):return self.send([])
            if path.endswith('/edit'):return self.send({'assetId':path.split('/')[2],'actions':[],'baseDimensions':{'width':600,'height':400}})
            identifier=path.split('/')[2]
            if identifier==VIDEO_ID: return self.send(asset(5))
            value=asset(1);value['id']=identifier;return self.send(value)
        if path=='/albums':return self.send([ALBUM, HARBOR])
        if path=='/shared-links':
            album=q.get('albumId',[None])[0]
            return self.send([HARBOR_LINK] if album in (None, HARBOR['id']) else [])
        if path=='/people':
            many=MANY_PEOPLE_TOKEN in (self.headers.get('x-immich-user-token'),self.headers.get('Authorization','').removeprefix('Bearer '))
            people=MANY_PEOPLE if many else [PERSON]
            return self.send({'people':people,'total':len(people),'hidden':0,'hasNextPage':False})
        if path=='/users/me':return self.send({'id':OWNER,'name':'Test library','email':'fixture@example.test'})
        if path=='/users/me/preferences':return self.send({'memories':{'enabled':True,'duration':5},'people':{'enabled':True,'sidebarWeb':False}})
        if path=='/memories':return self.send(memories())
        if path=='/map/markers':return self.send([{'id':asset(i)['id'],'lat':lat,'lon':lon,'city':city,'country':country} for i,(lat,lon,city,country) in enumerate([(52.3676,4.9041,'Amsterdam','Netherlands'),(38.7223,-9.1393,'Lisbon','Portugal'),(64.1466,-21.9426,'Reykjavik','Iceland'),(35.6762,139.6503,'Tokyo','Japan')])])
        if path=='/server/features':return self.send({k:True for k in ['passwordLogin','smartSearch','ocr','facialRecognition','map','trash','sidecar','realtimeTranscoding']}|{'oauth':False})
        if path=='/server/version':return self.send({'major':3,'minor':3,'patch':3})
        if path=='/assets/statistics':return self.send({'images':24000,'videos':0,'total':24000})
        return self.send([])
    def mutable_get(self,library,path,q):
        # The session's own library: its timeline, photos and albums as its changes left them.
        developed=q.get('isDeveloped',[''])[0]=='true'
        with library.lock:
            if path=='/timeline/buckets': self.send(mutable_buckets(library,q,developed)); return True
            if path=='/timeline/bucket': self.send(mutable_bucket(library,q.get('timeBucket',['2026-12-01'])[0][:10],q,developed)); return True
            if path.startswith('/assets/') and path.count('/')==2:
                value=mutable_asset(library,path.split('/')[2])
                if value is None: self.send_immich_error(404,'Asset not found')
                else: self.send(value)
                return True
            if path=='/albums': self.send(mutable_albums(library)); return True
        return False
    def mutable_change(self,library,method,path,body):
        # Changes to the session's library. Answers as Immich does; False for anything else.
        with library.lock:
            ids=[i for i in body.get('ids',[]) if isinstance(i,str)]
            if method=='PUT' and path=='/assets':
                for i in ids:
                    if 'isFavorite' in body: library.favorite[i]=bool(body['isFavorite'])
                    if 'visibility' in body: library.visibility[i]=body['visibility']
                self.send_empty(); return True
            if method=='PUT' and path.startswith('/assets/') and path.count('/')==2:
                identifier=path.split('/')[2]
                if 'isFavorite' in body: library.favorite[identifier]=bool(body['isFavorite'])
                if 'visibility' in body: library.visibility[identifier]=body['visibility']
                value=mutable_asset(library,identifier)
                if value is None: self.send_immich_error(404,'Asset not found')
                else: self.send(value)
                return True
            if method=='DELETE' and path=='/assets':
                if body.get('force'): library.deleted.update(ids); library.trashed.difference_update(ids)
                else: library.trashed.update(i for i in ids if i not in library.deleted)
                self.send_empty(); return True
            if method=='POST' and path=='/trash/restore/assets':
                restored=library.trashed.intersection(ids); library.trashed.difference_update(restored)
                self.send({'count':len(restored)}); return True
            if method=='POST' and path=='/trash/restore':
                count=len(library.trashed); library.trashed.clear(); self.send({'count':count}); return True
            if method=='POST' and path=='/trash/empty':
                count=len(library.trashed); library.deleted.update(library.trashed); library.trashed.clear(); self.send({'count':count}); return True
            if method=='POST' and path=='/albums':
                identifier=str(uuid.uuid4()); members=set(i for i in body.get('assetIds',[]) if isinstance(i,str))
                library.created[identifier]={'id':identifier,'albumName':body.get('albumName',''),'assetCount':len(members),'shared':False,
                                             'albumUsers':[],'albumThumbnailAssetId':None,'updatedAt':'2026-12-01T12:00:00Z'}
                library.added[identifier]=members
                self.send([a for a in mutable_albums(library) if a['id']==identifier][0],201); return True
            parts=path.split('/')
            if len(parts)==4 and parts[1]=='albums' and parts[3]=='assets' and method in ('PUT','DELETE'):
                album=parts[2]; added=library.added.setdefault(album,set()); removed=library.removed.setdefault(album,set())
                results=[]
                for i in ids:
                    present=in_album(library,album,i) and (album in library.created or i in added)
                    if method=='PUT':
                        if present: results.append({'id':i,'success':False,'error':'duplicate'}); continue
                        added.add(i); removed.discard(i)
                    else: removed.add(i); added.discard(i)
                    results.append({'id':i,'success':True})
                self.send(results); return True
            if len(parts)==3 and parts[1]=='albums' and method=='PATCH':
                fields=library.album_fields.setdefault(parts[2],{})
                for key in ('albumName','albumThumbnailAssetId','description'):
                    if key in body: fields[key]=body[key]
                found=[a for a in mutable_albums(library) if a['id']==parts[2]]
                if found: self.send(found[0])
                else: self.send_immich_error(404,'Album not found')
                return True
        return False
    def do_PUT(self): self.change()
    def do_DELETE(self): self.change()
    def do_PATCH(self): self.change()
    def change(self):
        library=mutable_library(self.token())
        if library is None: return self.unsupported()
        path=urllib.parse.urlsplit(self.path).path.removeprefix('/api')
        if not self.mutable_change(library,self.command,path,self.read_body()): self.send({})
    def do_POST(self):
        size=int(self.headers.get('Content-Length','0'));body=json.loads(self.rfile.read(size) or b'{}');path=urllib.parse.urlsplit(self.path).path.removeprefix('/api')
        library=mutable_library(self.token())
        if library is not None and self.mutable_change(library,'POST',path,body): return
        if path=='/auth/login':
            email=body.get('email','')
            token=EXPIRED_TOKEN if email.startswith('expired') else SESSION_TOKEN
            return self.send({'accessToken':token,'userId':OWNER,'userEmail':email,'name':'Test library','isAdmin':False,
                              'shouldChangePassword':False,'profileImagePath':'','isOnboarded':True},201)
        if path=='/auth/validateToken':
            if self.token()==EXPIRED_TOKEN: return self.send_immich_error(401,'Invalid user token')
            return self.send({'authStatus':True})
        if path=='/auth/logout':return self.send({'successful':True,'redirectUri':'/auth/login?autoLaunch=0'})
        if path.startswith('/search/'):
            if 'unavailable' in body.get('query',''):return self.send({'error':'Fixture unavailable'},503)
            cursor=body.get('cursor');items=[] if cursor is None else [asset(i) for i in range(9)]
            return self.send({'assets':{'items':items,'count':len(items),'nextCursor':'verified-page-2' if cursor is None else None},'verification':{'status':'complete','checked':10,'rejected':10-len(items)}})
        return self.send({})

if __name__=='__main__':
    FixtureHTTPServer(('127.0.0.1',18091),Handler).serve_forever()
