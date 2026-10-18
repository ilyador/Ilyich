#!/usr/bin/env python3
"""Loopback-only synthetic library for native UI tests. No account or photo data."""
import datetime
import hashlib
import http.server
import json
import math
import struct
import urllib.parse
import uuid
import zlib

OWNER = '00000000-0000-4000-8000-000000000001'
BUCKETS = [{'timeBucket': f'{2026-i//12:04d}-{12-i%12:02d}-01', 'count': 100} for i in range(240)]
PERSON = {'id': '00000000-0000-4000-8000-000000000002', 'name': 'Maya', 'isHidden': False, 'isFavorite': True}
ALBUM = {'id': '00000000-0000-4000-8000-000000000003', 'albumName': 'Coast', 'assetCount': 100, 'shared': False,
         'albumUsers': [], 'albumThumbnailAssetId': None, 'updatedAt': '2026-12-01T12:00:00Z'}

def asset(index, date='2026-12-01'):
    return {'id': str(uuid.uuid5(uuid.NAMESPACE_URL, date + str(index))), 'ownerId': OWNER,
            'type': 'IMAGE', 'originalFileName': f'Test landscape {index}.jpg',
            'fileCreatedAt': date+'T12:00:00Z', 'localDateTime': date+'T12:00:00Z',
            'width': 600, 'height': 400, 'isFavorite': False, 'isTrashed': False,
            'isEdited': False, 'isDeveloped': index % 7 == 0, 'visibility': 'timeline',
            'mediaRevision': 'fixture-1', 'duration': None, 'exifInfo': {
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
    specs = [('00000000-0000-4000-8000-0000000000a1', 'Maya Memory One', 3, range(0, 3)),
             ('00000000-0000-4000-8000-0000000000a2', 'Maya Memory Two', 1, range(3, 5))]
    result = []
    for identifier, name, years, indexes in specs:
        at = now.replace(year=now.year - years) if not (now.month == 2 and now.day == 29) else now.replace(year=now.year - years, day=28)
        result.append({'id': identifier, 'type': 'on_this_day', 'ownerId': OWNER, 'isSaved': False,
                       'memoryAt': iso(at), 'showAt': iso(start), 'hideAt': iso(start + datetime.timedelta(days=1)),
                       'createdAt': iso(start), 'updatedAt': iso(start), 'seenAt': None,
                       'data': {'year': at.year, 'personId': PERSON['id'], 'personName': name},
                       'assets': [asset(i) for i in indexes]})
    return result

def bucket(date):
    assets = [asset(i,date) for i in range(100)]
    return {key: [a.get(key) for a in assets] for key in ['id','ownerId','isFavorite','isTrashed','visibility','fileCreatedAt','duration','mediaRevision']} | {
        'ratio': [1.5]*100, 'isImage': [True]*100, 'createdAt':[date+'T12:00:00Z']*100,
        'localOffsetHours':[0]*100, 'thumbhash':[None]*100, 'livePhotoVideoId':[None]*100,
    }

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

class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self,*args): pass
    def send(self,value,status=200):
        data=json.dumps(value).encode();self.send_response(status);self.send_header('Content-Type','application/json');self.send_header('Content-Length',str(len(data)));self.end_headers();self.wfile.write(data)
    def do_GET(self):
        url=urllib.parse.urlsplit(self.path);path=url.path.removeprefix('/api');q=urllib.parse.parse_qs(url.query)
        if path.endswith('/thumbnail'):
            data=test_image(path);self.send_response(200);self.send_header('Content-Type','image/png');self.send_header('Content-Length',str(len(data)));self.send_header('Cache-Control','max-age=3600');self.end_headers();self.wfile.write(data);return
        if path=='/timeline/buckets':return self.send(BUCKETS)
        if path=='/timeline/bucket':return self.send(bucket(q.get('timeBucket',['2026-12-01'])[0][:10]))
        if path.startswith('/assets/'):
            if path.endswith('/ocr'):return self.send([])
            if path.endswith('/edit'):return self.send({'assetId':path.split('/')[2],'actions':[],'baseDimensions':{'width':600,'height':400}})
            value=asset(1);value['id']=path.split('/')[2];return self.send(value)
        if path=='/albums':return self.send([ALBUM])
        if path=='/people':return self.send({'people':[PERSON],'total':1,'hidden':0,'hasNextPage':False})
        if path=='/users/me':return self.send({'id':OWNER,'name':'Test library','email':'fixture@example.test'})
        if path=='/users/me/preferences':return self.send({'memories':{'enabled':True,'duration':5},'people':{'enabled':True,'sidebarWeb':False}})
        if path=='/memories':return self.send(memories())
        if path=='/map/markers':return self.send([{'id':asset(i)['id'],'lat':lat,'lon':lon,'city':city,'country':country} for i,(lat,lon,city,country) in enumerate([(52.3676,4.9041,'Amsterdam','Netherlands'),(38.7223,-9.1393,'Lisbon','Portugal'),(64.1466,-21.9426,'Reykjavik','Iceland'),(35.6762,139.6503,'Tokyo','Japan')])])
        if path=='/server/features':return self.send({k:True for k in ['passwordLogin','smartSearch','ocr','facialRecognition','map','trash','sidecar','realtimeTranscoding']}|{'oauth':False})
        if path=='/server/version':return self.send({'major':3,'minor':3,'patch':3})
        if path=='/assets/statistics':return self.send({'images':24000,'videos':0,'total':24000})
        return self.send([])
    def do_POST(self):
        size=int(self.headers.get('Content-Length','0'));body=json.loads(self.rfile.read(size) or b'{}');path=urllib.parse.urlsplit(self.path).path.removeprefix('/api')
        if path.startswith('/search/'):
            if 'unavailable' in body.get('query',''):return self.send({'error':'Fixture unavailable'},503)
            cursor=body.get('cursor');items=[] if cursor is None else [asset(i) for i in range(9)]
            return self.send({'assets':{'items':items,'count':len(items),'nextCursor':'verified-page-2' if cursor is None else None},'verification':{'status':'complete','checked':10,'rejected':10-len(items)}})
        return self.send({})

if __name__=='__main__':
    http.server.ThreadingHTTPServer(('127.0.0.1',18091),Handler).serve_forever()
