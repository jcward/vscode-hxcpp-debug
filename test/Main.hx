package;

class Main {
  static function main() {
    var things = [];
    things.push( new Thing() );
    things.push( new Thing() );

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

    while (true) {
      trace("blah");
      Sys.sleep(1);
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
