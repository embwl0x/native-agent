// Tables describe their data extent and publish populated cells only.
function read(request) { SenseIWork.readFormat("numbers", request); }
function watch() { sense.source.watch(); }
function changed(material) { NativeKit.changed(material); }
