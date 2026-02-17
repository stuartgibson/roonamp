const RoonApi = require('node-roon-api');
const RoonApiTransport = require('node-roon-api-transport');
const RoonApiImage = require('node-roon-api-image');
const http = require('http');

let core;
let transport;
let imageService;

const roon = new RoonApi({
    extension_id: 'com.yourcompany.roonamp',
    display_name: 'Roonamp',
    display_version: '1.0.0',
    publisher: 'Your Name',
    email: 'your.email@example.com',
    core_paired: (pairedCore) => {
        console.log('PAIRED:', pairedCore.display_name);
        core = pairedCore;
        transport = core.services.RoonApiTransport;
        imageService = core.services.RoonApiImage;
        
        if (imageService) {
            console.log('✅ Image service available');
        } else {
            console.log('⚠️ Image service not available');
        }
    },
    core_unpaired: () => {
        console.log('UNPAIRED');
        core = null;
        transport = null;
        imageService = null;
    }
});

roon.init_services({
    required_services: [RoonApiTransport, RoonApiImage]
});

roon.start_discovery();

const server = http.createServer((req, res) => {
    res.setHeader('Access-Control-Allow-Origin', '*');
    
    const url = new URL(req.url, 'http://localhost:3000');
    
    console.log('Request:', req.method, url.pathname);
    
    if (url.pathname === '/status') {
        res.setHeader('Content-Type', 'application/json');
        res.end(JSON.stringify({ 
            connected: !!core,
            core_name: core?.display_name 
        }));
    } else if (url.pathname === '/zones') {
        res.setHeader('Content-Type', 'application/json');
        if (!transport) {
            res.statusCode = 503;
            res.end(JSON.stringify({ error: 'Not connected' }));
            return;
        }
        transport.get_zones((err, zones) => {
            if (err) {
                res.statusCode = 500;
                res.end(JSON.stringify({ error: err.message }));
            } else {
                res.end(JSON.stringify(zones || {}));
            }
        });
    } else if (url.pathname.startsWith('/image/')) {
        // Handle image requests
        const imageKey = decodeURIComponent(url.pathname.substring(7));
        
        console.log('Image request for key:', imageKey);
        
        if (!imageService) {
            console.error('Image service not available - not connected to core');
            res.statusCode = 503;
            res.setHeader('Content-Type', 'application/json');
            res.end(JSON.stringify({ error: 'Not connected to Roon Core' }));
            return;
        }
        
        const options = {
            scale: 'fit',
            width: 600,
            height: 600,
            format: 'image/jpeg'
        };
        
        imageService.get_image(imageKey, options, (err, contentType, imageData) => {
            if (err) {
                console.error('Image error:', err);
                res.statusCode = 404;
                res.setHeader('Content-Type', 'application/json');
                res.end(JSON.stringify({ error: 'Image not found: ' + err.message }));
            } else {
                console.log('Image delivered:', contentType, imageData.length, 'bytes');
                res.setHeader('Content-Type', contentType);
                res.setHeader('Cache-Control', 'public, max-age=86400');
                res.end(imageData);
            }
        });
    } else if (url.pathname === '/control' || url.pathname.startsWith('/control/')) {
        res.setHeader('Content-Type', 'application/json');
        if (!transport) {
            res.statusCode = 503;
            res.end(JSON.stringify({ error: 'Not connected' }));
            return;
        }
        
        // Support both formats:
        // 1. POST /control with JSON body { zone_id, control }
        // 2. POST /control/{zone_id}/{command}
        
        if (url.pathname.startsWith('/control/')) {
            // Format: /control/{zone_id}/{command}
            const parts = url.pathname.split('/').filter(p => p);
            if (parts.length >= 3) {
                const zoneId = parts[1];
                const command = parts[2];
                
                console.log('Control request:', command, 'for zone:', zoneId);
                
                transport.control(zoneId, command, (err) => {
                    if (err) {
                        console.error('Control error:', err);
                        res.statusCode = 500;
                        res.end(JSON.stringify({ error: err.message }));
                    } else {
                        console.log('✅ Control succeeded:', command);
                        res.end(JSON.stringify({ success: true }));
                    }
                });
            } else {
                res.statusCode = 400;
                res.end(JSON.stringify({ error: 'Invalid control path' }));
            }
        } else {
            // Format: POST /control with JSON body
            let body = '';
            req.on('data', chunk => { body += chunk; });
            req.on('end', () => {
                try {
                    const { zone_id, control } = JSON.parse(body);
                    transport.control(zone_id, control, (err) => {
                        if (err) {
                            res.statusCode = 500;
                            res.end(JSON.stringify({ error: err.message }));
                        } else {
                            res.end(JSON.stringify({ success: true }));
                        }
                    });
                } catch (e) {
                    res.statusCode = 400;
                    res.end(JSON.stringify({ error: 'Invalid JSON' }));
                }
            });
        }
    } else {
        res.statusCode = 404;
        res.setHeader('Content-Type', 'application/json');
        res.end(JSON.stringify({ error: 'Not found' }));
    }
});

server.listen(3000, () => {
    console.log('Bridge server listening on port 3000');
    console.log('Waiting for Roon Core to connect...');
});
