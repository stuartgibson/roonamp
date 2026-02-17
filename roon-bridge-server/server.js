const RoonApi = require('node-roon-api');
const RoonApiTransport = require('node-roon-api-transport');
const RoonApiImage = require('node-roon-api-image');
const http = require('http');

let core;
let transport;
let imageService;
let zones = {};
let queueCache = {};
let queueSubs = {}; // active subscription handles per zone

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

        // Subscribe to zone updates for live data
        transport.subscribe_zones((response, msg) => {
            if (response === "Subscribed") {
                zones = {};
                if (msg.zones) {
                    msg.zones.forEach(z => {
                        zones[z.zone_id] = z;
                    });
                }
                console.log(`✅ Subscribed to ${Object.keys(zones).length} zones`);
            } else if (response === "Changed") {
                if (msg.zones_removed) msg.zones_removed.forEach(id => delete zones[id]);
                if (msg.zones_added) msg.zones_added.forEach(z => {
                    zones[z.zone_id] = z;
                });
                if (msg.zones_changed) msg.zones_changed.forEach(z => {
                    zones[z.zone_id] = z;
                });
                if (msg.zones_seek_changed) msg.zones_seek_changed.forEach(z => {
                    if (zones[z.zone_id]) {
                        if (zones[z.zone_id].now_playing) {
                            zones[z.zone_id].now_playing.seek_position = z.seek_position;
                        }
                        zones[z.zone_id].queue_time_remaining = z.queue_time_remaining;
                    }
                });
            }
        });
    },
    core_unpaired: () => {
        console.log('UNPAIRED');
        core = null;
        transport = null;
        imageService = null;
        zones = {};
        queueCache = {};
        queueSubs = {};
    }
});

roon.init_services({
    required_services: [RoonApiTransport, RoonApiImage]
});

roon.start_discovery();

const server = http.createServer((req, res) => {
    res.setHeader('Access-Control-Allow-Origin', '*');

    const url = new URL(req.url, 'http://localhost:3000');

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
        const zonesArray = Object.values(zones);
        res.end(JSON.stringify({ zones: zonesArray }));
    } else if (url.pathname.startsWith('/image/')) {
        const imageKey = decodeURIComponent(url.pathname.substring(7));

        if (!imageService) {
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
                res.statusCode = 404;
                res.setHeader('Content-Type', 'application/json');
                res.end(JSON.stringify({ error: 'Image not found: ' + err.message }));
            } else {
                res.setHeader('Content-Type', contentType);
                res.setHeader('Cache-Control', 'public, max-age=86400');
                res.end(imageData);
            }
        });
    } else if (url.pathname.startsWith('/settings/')) {
        res.setHeader('Content-Type', 'application/json');
        if (!transport) {
            res.statusCode = 503;
            res.end(JSON.stringify({ error: 'Not connected' }));
            return;
        }

        const zoneId = decodeURIComponent(url.pathname.substring('/settings/'.length));
        let body = '';
        req.on('data', chunk => { body += chunk; });
        req.on('end', () => {
            try {
                const body_settings = JSON.parse(body);
                console.log('Settings change request:', zoneId, body_settings);
                transport.change_settings(zoneId, body_settings, (err) => {
                    if (err) {
                        console.error('Settings error:', err);
                        res.statusCode = 500;
                        res.end(JSON.stringify({ error: err.message }));
                    } else {
                        console.log('✅ Settings changed:', body_settings);
                        res.end(JSON.stringify({ success: true }));
                    }
                });
            } catch (e) {
                res.statusCode = 400;
                res.end(JSON.stringify({ error: 'Invalid JSON' }));
            }
        });
    } else if (url.pathname.startsWith('/volume/')) {
        res.setHeader('Content-Type', 'application/json');
        if (!transport) {
            res.statusCode = 503;
            res.end(JSON.stringify({ error: 'Not connected' }));
            return;
        }

        const outputId = decodeURIComponent(url.pathname.substring('/volume/'.length));
        let body = '';
        req.on('data', chunk => { body += chunk; });
        req.on('end', () => {
            try {
                const { how, value } = JSON.parse(body);
                console.log('Volume change request:', outputId, how, value);
                transport.change_volume(outputId, how, value, (err) => {
                    if (err) {
                        console.error('Volume error:', err);
                        res.statusCode = 500;
                        res.end(JSON.stringify({ error: err.message }));
                    } else {
                        console.log('✅ Volume changed:', how, value);
                        res.end(JSON.stringify({ success: true }));
                    }
                });
            } catch (e) {
                res.statusCode = 400;
                res.end(JSON.stringify({ error: 'Invalid JSON' }));
            }
        });
    } else if (url.pathname === '/control' || url.pathname.startsWith('/control/')) {
        res.setHeader('Content-Type', 'application/json');
        if (!transport) {
            res.statusCode = 503;
            res.end(JSON.stringify({ error: 'Not connected' }));
            return;
        }

        if (url.pathname.startsWith('/control/')) {
            const parts = url.pathname.split('/').filter(p => p);
            if (parts.length >= 3) {
                const zoneId = parts[1];
                const command = parts.slice(2).join('/');

                console.log('Control request:', command, 'for zone:', zoneId);

                if (command.startsWith('seek/')) {
                    const seconds = parseInt(command.split('/')[1]);
                    transport.seek(zoneId, 'absolute', seconds, (err) => {
                        if (err) {
                            console.error('Seek error:', err);
                            res.statusCode = 500;
                            res.end(JSON.stringify({ error: err.message }));
                        } else {
                            console.log('✅ Seek succeeded:', seconds, 'seconds');
                            res.end(JSON.stringify({ success: true }));
                        }
                    });
                } else {
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
                }
            } else {
                res.statusCode = 400;
                res.end(JSON.stringify({ error: 'Invalid control path' }));
            }
        } else {
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
    } else if (url.pathname.startsWith('/queue/')) {
        res.setHeader('Content-Type', 'application/json');
        if (!transport) {
            res.statusCode = 503;
            res.end(JSON.stringify({ error: 'Not connected' }));
            return;
        }

        const zoneId = decodeURIComponent(url.pathname.substring('/queue/'.length));

        // Unsubscribe any existing subscription, then re-subscribe to get fresh data
        if (queueSubs[zoneId]) {
            try { queueSubs[zoneId].unsubscribe(); } catch(e) {}
            delete queueSubs[zoneId];
        }

        let responded = false;
        queueSubs[zoneId] = transport.subscribe_queue(zoneId, 100, (response, msg) => {
            if (msg && msg.items) {
                queueCache[zoneId] = msg.items;
            }
            // Respond on the first callback (Subscribed) with fresh data
            if (!responded) {
                responded = true;
                res.end(JSON.stringify({ items: queueCache[zoneId] || [] }));
            }
        });

        // Timeout fallback — return cached data if subscription is slow
        setTimeout(() => {
            if (!responded) {
                responded = true;
                res.end(JSON.stringify({ items: queueCache[zoneId] || [] }));
            }
        }, 2000);

    } else if (url.pathname.startsWith('/play_from_here/')) {
        res.setHeader('Content-Type', 'application/json');
        if (!transport) {
            res.statusCode = 503;
            res.end(JSON.stringify({ error: 'Not connected' }));
            return;
        }

        const parts = url.pathname.split('/').filter(p => p);
        if (parts.length >= 3) {
            const zoneId = decodeURIComponent(parts[1]);
            const queueItemId = parseInt(parts[2]);
            console.log('Play from here:', zoneId, 'item:', queueItemId);

            transport.play_from_here(zoneId, queueItemId, (err) => {
                if (err) {
                    console.error('Play from here error:', err);
                    res.statusCode = 500;
                    res.end(JSON.stringify({ error: String(err) }));
                } else {
                    console.log('✅ Playing from queue item:', queueItemId);
                    res.end(JSON.stringify({ success: true }));
                }
            });
        } else {
            res.statusCode = 400;
            res.end(JSON.stringify({ error: 'Invalid path: /play_from_here/:zoneId/:queueItemId' }));
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
