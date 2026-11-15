# A small stand-in dev image for the smoke jobs. Busybox has no bash, and the
# exported invocation falls back to /bin/sh. The marker tells a candidate from the pin.
FROM busybox:musl
RUN echo candidate >/etc/dev-image-candidate
