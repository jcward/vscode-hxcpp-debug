package;

import cpp.vm.Thread;
import cpp.vm.Deque;
import haxe.io.Input;
import haxe.io.Bytes;

#if debug
import debugger.HaxeRemote;
#end

class Main {
  static function main() {
#if debug
    new debugger.HaxeRemote(true, "localhost");
    //new debugger.Local(true);
#end

    // var abcd:String = null;
    // trace(abcd.length); // 0 ???

    // var abcd:Array<Dynamic> = [];
    // trace(abcd[3].length); // Null Object Exception

    // var p = new sys.io.Process("haxe", ["build.hxml"]);
    // trace(p.exitCode());
    // var output = p.stdout.readAll();
    // trace(output.getString(0, output.length));

    // var r = ~/(?:[^\s"]+|"[^"]*")+/g;
    // var args = [];
    //               trace(r.map('Hello World "and this" and that',
    //                           function(r):String {
    //                             args.push(r.matched(0));
    //                             return '';
    //                           }));
    //               trace(args);

    // while (true) {
    //   Sys.stdout().writeString("(c)reate a new Thing, or (q)uit ?\n");
    //   Sys.stdout().flush(); // neko
    //   var i = Sys.getChar(true);
    //   //var i = Sys.stdin().readByte();
    //   trace(i);
    //   if (i==113) break;
    //   //if (i.substr(0,1)=='q') break;
    // }
    // trace("Goodbye!");

    // trace("Launching...");
    // var p = new sys.io.Process("ping", ["10.0.1.1", "-c", "3"]);
    // while (true) {
    //   try {
    //     trace(p.stdout.readByte());
    //   } catch (e:Dynamic) {
    //     // exited
    //     break;
    //   }
    // }
    // trace("Exit code: "+p.exitCode());

    //async_test();

    thread_test();

    // while (true) {
    //   var i = Sys.getChar(true);
    //   trace("read: "+i);
    //   Sys.sleep(1);
    // }
  }

  static function thread_test() {
    Thread.create(thread_test_int).sendMessage("First");
    Thread.create(thread_test_int).sendMessage("Second");

    for (i in 0...300) {
      Sys.sleep(0.1);
    }
    trace("Leaving Main thread");
  }

  static function thread_test_int() {
    var name:String = Thread.readMessage(true);
    trace("In thread: "+name);
    var a = new cpp.Random().int(100000);
    for (i in 0...200) {
      Sys.sleep(0.1);
      a += i;
    }
    trace("Leaving thread "+name+". a="+a);
  }


  static function test_things() {
    var things = [];
    things.push( new Thing() );
    things.push( new Thing() );
    trace(things);

    trace("..."); // test break, change things

    trace(things);
  }

  public static function wont_pause_issue_12():Void
  {
    var myValue = "abcd1234";
    while(true) { }
  }

  public static function async_test():Void
  {
    var a:AsyncInput = new AsyncInput(Sys.stdin());
    while (true) {
      if (a.hasData()) {
        trace("Read: "+a.readByte());
      } else {
        trace("No data for now...");
        Sys.sleep(0.5);
      }
    }
  }
}

class Thing
{
  static var salutations = ["Hi", "Hello", "Bonjour"];
  static var inst_id:Int = 1;

  var name:String;

  public function new()
  {
    name = "Thing #"+(inst_id++);
    random_greet();
  }

  public function random_greet():Void
  {
    var idx = Std.int(Math.random()*salutations.length);
    var rnd_salutation = salutations[idx];
    greet(rnd_salutation);
  }

  public function greet(salutation:String):Void
  {
    trace(salutation+", I'm "+name);
  }
}


class AsyncInput {
  var _input:Input;
  var _data:Deque<Int>;

  public function new(i:Input) {
    _input = i;
    _data = new Deque<Int>();
    var t = Thread.create(readInput);
    t.sendMessage(_input);
    t.sendMessage(_data);
  }

  var buffer:Null<Int> = null;
  public function hasData():Bool // non-blocking
  {
    if (buffer!=null) return true;
    buffer = _data.pop(false);
    return (buffer!=null);
  }

  public function readByte():Int // blocking
  {
    var rtn:Int = 0;
    if (buffer==null) { buffer = _data.pop(true); }
    rtn = buffer;
    buffer = null;
    return rtn;
  }

  public function read(num_bytes:Int):Bytes // blocking
  {
    var rtn:Bytes = Bytes.alloc(num_bytes);
    var ptr:Int = 0;
    while (ptr<num_bytes) rtn.set(ptr++, readByte());
    return rtn;
  }

  // Thread
  static private function readInput()
  {
    var _input:Input = Thread.readMessage(true);
    var _data:Deque<Int> = Thread.readMessage(true);

    trace("Waiting to read something! on "+_input+" for "+_data);

    while (true) {
      _data.add(_input.readByte());
      trace("Read something!");
    }
  }

}
