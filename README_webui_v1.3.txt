TS4500 -> NFS -> Scalar i3 Web UI v1.3
=======================================

Included production components
------------------------------
- index_ts4500Toscalari3_v1.3.html
- wsmanager_ts4500Toscalari3_v1.4.sh
- ts4500_ops_v1.6.sh
- scalari3_tape_write_v1.4.sh
- ts4500Toscalari3-websocketd_v1.4.service

Why wsmanager is v1.4
---------------------
The previous v1.3 backend supported Scalar i3 v1.4 mbuffer write controls, but
TS4500 tape-read/recover did not forward the new ts4500_ops_v1.6 mbuffer
parameters. v1.4 keeps the v1.3 allow-list protocol and adds:
  read_mode=mbuffer|direct
  buffer_mem=<size>
  block_size=<size>
for TS4500 TAPE_READ and RECOVER actions.

Web UI v1.3 additions
---------------------
- TS4500 Read Mode: mbuffer / direct tar
- Scalar Write Mode: mbuffer / direct tar
- Shared Buffer Memory and Block Size controls (defaults 6G / 1M)
- TS4500 Restore Runtime panel
  * read mode
  * buffer utilization when mbuffer status is visible
  * buffer memory / block size
  * elapsed time
  * mbuffer output rate when available
  * VOLSER / tape device / NFS destination
  * recovered files / bytes
- Existing Scalar i3 Write Runtime remains supported.
- Production baseline updated to TS4500 v1.6 and Scalar i3 v1.4.

Default TS4500 restore path
---------------------------
  /dev/IBMtape0 -> mbuffer -m 6G -s 1M -> tar -> NFS

Default Scalar write path
-------------------------
  tar -> mbuffer -m 6G -s 1M -> /dev/tapedrv_test

Suggested deployment
--------------------
cd /ws/ts4500Toscalari3

# Copy the versioned files here first, then:
chmod 700 ts4500_ops_v1.6.sh
chmod 700 scalari3_tape_write_v1.4.sh
chmod 700 wsmanager_ts4500Toscalari3_v1.4.sh
chmod 644 index_ts4500Toscalari3_v1.3.html

# If your static root expects index.html:
ln -sfn index_ts4500Toscalari3_v1.3.html index.html

# Install/update systemd service:
cp ts4500Toscalari3-websocketd_v1.4.service \
  /etc/systemd/system/ts4500Toscalari3-websocketd.service
systemctl daemon-reload
systemctl restart ts4500Toscalari3-websocketd.service
systemctl status ts4500Toscalari3-websocketd.service --no-pager -l

Validation
----------
bash -n ts4500_ops_v1.6.sh
bash -n scalari3_tape_write_v1.4.sh
bash -n wsmanager_ts4500Toscalari3_v1.4.sh
command -v mbuffer

Backend mappings verified during build
--------------------------------------
TS4500 tape-read mbuffer:
  tape-read CDT018L7 --preserve-owner --mbuffer --buffer-mem 6G --block-size 1M

TS4500 recover direct:
  recover CDT018L7 --probe-entries 10 --no-mbuffer --after keep

Scalar production write mbuffer:
  run --verify probe --probe-entries 10 --heartbeat-sec 60 \
      --buffer-mem 6G --block-size 1M --keep
