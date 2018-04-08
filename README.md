# vdrtranscode
This is a docker container for the vdrtranscode script. You can find more information on vdrtranscode in the vdr wiki http://vdr-wiki.de/wiki/index.php/VdrTranscode

You need to mount your vdr recording directory to /var/lib/video.00 and your output directory to /video/to_convert

You have to adjust your vdrtranscode.conf and map it to /etc/vdrtranscode.conf

To start a transcode job you have to start it like described in the vdr wiki.
