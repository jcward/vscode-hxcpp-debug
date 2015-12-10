package;

import haxe.io.Input;
import haxe.io.Bytes;

import cpp.vm.Thread;
import cpp.vm.Deque;

class AsyncInput {
  var _data:Deque<Int>;
  var _closed:Deque<Bool>;
  var _is_closed:Bool = false;

  public function new(i:Input) {
    _data = new Deque<Int>();
    _closed = new Deque<Bool>();
    var t = Thread.create(readInput);
    t.sendMessage(i);
    t.sendMessage(_data);
    t.sendMessage(_closed);
  }

  inline function is_data_empty():Bool {
    if (_is_closed) return true;
    if (buffer!=null) return false;
    buffer = _data.pop(false);
    return buffer==null;
  }

  inline function check_closed():Bool {
    if (!is_data_empty()) return false;
    return _is_closed || (_is_closed = _closed.pop(false)==true);
  }

  public function isClosed():Bool { return check_closed(); }

  var buffer:Null<Int> = null;
  public function hasData():Bool // non-blocking
  {
    if (is_data_empty()) return false; // checks closed, loads buffer
    return (buffer!=null);
  }

  public function readByte():Int // blocking
  {
    var rtn:Int = 0;
    if (check_closed()) throw new haxe.io.Eof();
    if (buffer==null) { buffer = _data.pop(true); } // blocking
    rtn = buffer;
    buffer = null;
    return rtn;
  }

  public function read(num_bytes:Int):Bytes // blocking
  {
    if (check_closed()) throw new haxe.io.Eof();
    var rtn:Bytes = Bytes.alloc(num_bytes);
    var ptr:Int = 0;
    while (ptr<num_bytes) {
      rtn.set(ptr++, readByte());
      if (_is_closed) break; // should throw? or return partial data?
    }
    return rtn;
  }

  // Thread
  static var inst = 0;
  static private function readInput()
  {
    var _input:Input = Thread.readMessage(true);
    var _data:Deque<Int> = Thread.readMessage(true);
    var _closed:Deque<Bool> = Thread.readMessage(true);
    //var mirror = sys.io.File.append("/tmp/input.bin."+(inst++), false);

    while (true) {
      var b:Int = 0;
      try {
        b = _input.readByte();
      } catch (e:haxe.io.Eof) {
        break;
      }
      //mirror.writeByte(b);
      //mirror.flush();
      _data.add(b);
    }

    _closed.add(true);
  }
}
