If you are thinking of using Alpine Linux in this NAS, and especially on diskless mode, Alpine Linux in 3.24 version, doesn't update the kernel automatically. You had to use update-kernel utility.

But in this NAS device, it downloads like 700MB additional files just for that. That is not desirable as we have only 1GB nand flash(actually very usable for simple NAS, I have 700MB empty space on this one).

And it ends in errors like no space left on the device. So I came up with this.

It uses one of the mounted disks mounted as /media/emre/750gb, downloads files there and applies the update.

This takes around 10-15 minutes. 
