package;

import haxe.io.Input;
import haxe.io.Output;
import haxe.io.Bytes;

import haxe.ds.StringMap;

import sys.io.Process;

import cpp.vm.Thread;
import cpp.vm.Deque;
import cpp.vm.Mutex;

import debugger.IController;

class Main {
  static function main() {
    var log = sys.io.File.append("/tmp/adapter.log", false);
    var input = Sys.stdin();
    if (Sys.args().length>0) {
      trace("Reading file input...");
      input = sys.io.File.read(Sys.args()[0], true);
    }
    new DebugAdapter(input, Sys.stdout(), log);
  }
}

class DebugAdapter {
  var _input:AsyncInput;
  var _output:Output;
  static var _log:Output;

  var _init_args:Dynamic;
  var _launch_req:Dynamic;
  var _exception_breakpoints_args:Dynamic;

  var _compile_process:Process;
  var _compile_stdout:AsyncInput;

  var _runCommand:String = null;
  var _runPath:String = null;
  var _runInTerminal:Bool = false;
  var _run_process:Process;

  var _sent_initialized:Bool = false;

  var _vsc_haxe_server:Thread;
  var _debugger_messages:Deque<Message>;
  var _debugger_commands:Deque<Command>;
  var _pending_responses:Array<Dynamic>; 

  public function new(i:Input, o:Output, log:Output) {
    _input = new AsyncInput(i);
    _output = o;
    _log = log;
    _log_mutex = new Mutex();

    _debugger_messages = new Deque<Message>();
    _debugger_commands = new Deque<Command>();

    _pending_responses = [];

    while (true) {
      if (_input.hasData() && outstanding_variables==null) read_from_vscode();
      if (_compile_process!=null) read_compile();
      if (_run_process!=null) check_debugger_messages();
      Sys.sleep(0.05);
    }
  }

  static public function do_throw(s:String) {
    log(s);
    throw s;
  }

  static var _log_mutex:Mutex;
  static public function log(s:String) {
    _log_mutex.acquire();
    _log.writeString(Sys.time()+": "+s+"\n");
    _log.flush();
    _log_mutex.release();
  }

  function burn_blank_line():Void
  {
    if (_input.readByte()!=13) log("Protocol error, expected 13");
    if (_input.readByte()!=10) log("Protocol error, expected 10");
  }

  // Let's see how this works in Windows before we go trying to improve it...
  function split_args(str:String):Array<String>
  {
    str = StringTools.replace(str, "\\ ", "_LITERAL_SPACE");
    var r = ~/(?:[^\s"]+|"[^"]*")+/g;
    var args = [];
    r.map(str,
          function(r):String {
            var match = r.matched(0);
            args.push(StringTools.replace(match ,"_LITERAL_SPACE", " "));
            return '';
          });
    return args;
  }

  function read_from_vscode():Void
  {
    var b:Int;
    var line:StringBuf = new StringBuf();
    while ((b=_input.readByte())!=10) {
      if (b!=13) line.addChar(b);
    }

    // Read header
    var values = line.toString().split(':');
    if (values[0]=="Content-Length") {
      burn_blank_line();
      handle_request(read_json(Std.parseInt(values[1])));
    } else {
      log("Ignoring unknown header:\n"+line.toString());
    }
  }

  function read_json(num_bytes:Int):Dynamic
  {
    log("Reading "+num_bytes+" bytes...");
    var json:String = _input.read(num_bytes).getString(0, num_bytes);
    log(json);
    return haxe.format.JsonParser.parse(json);
  }

  function send_response(response:Dynamic):Void
  {
    var json:String = haxe.format.JsonPrinter.print(response);
    var b = Bytes.ofString(json);

    log("Sending "+b.length+" bytes:");
    log(json);

    _output.writeString("Content-Length: "+b.length);
    _output.writeByte(13);
    _output.writeByte(10);
    _output.writeByte(13);
    _output.writeByte(10);
    _output.writeBytes(b, 0, b.length);
  }

  var _event_sequence:Int = 1;
  function send_event(event:Dynamic):Void
  {
    event.seq = _event_sequence++;
    event.type = "event";
    send_response(event);
  }

  function send_output(output:String, category:String='console', add_newline:Bool=true):Void
  {
    // Attempts at seeing all messages ???
    // output = StringTools.replace(output, "\"", "");
    // if (output.length>20) {
    //   output = output.substr(0,20);
    //   add_newline = true;
    // }

    var n = add_newline ? "\n" : "";

    if (output.indexOf("\n")>0) {
      // seems to choke on large (or multi-line) output, send separately
      var lines = output.split("\n");
      for (i in 0...lines.length) {
        var line = lines[i] + (i==lines.length-1 ? n : "\n");
        send_event({"event":"output", "body":{"category":category,"output":line}});
      }
    } else {
      send_event({"event":"output", "body":{"category":category,"output":(output+n)}});
    }
  }

  function handle_request(request:Dynamic):Void
  {
    var command:String = request.command;
    log("Got command: "+command);

    var response:Dynamic = {
      request_seq:request.seq,
      command:request.command,
      success:false
    }

    switch command {
      case "initialize": {
        log("Initializing...");
        _init_args = request.arguments;
        response.success = true;
        send_response(response);
      }
      case "launch": {
        log("Launching...");
        _launch_req = request;
        var compileCommand:String = null;
        var compilePath:String = null;
        for (arg in (_launch_req.arguments.args:Array<String>)) {
          var eq = arg.indexOf('=');
          var name = arg.substr(0, eq);
          var value = arg.substr(eq+1);
          log("Arg "+name+" is "+value);
          switch name {
            case "compileCommand": compileCommand = value;
            case "compilePath": compilePath = value;
            case "runCommand": _runCommand = value;
            case "runPath": _runPath = value;
            case "runInTerminal": _runInTerminal = (value.toLowerCase()=='true');
            default: log("Unknown arg name '"+name+"'"); do_disconnect();
          }
        }

        var success = true;
        if (compileCommand!=null) {
          log("Compiling...");
          send_output("Compiling...");
          _compile_process = start_process(compileCommand, compilePath);
          _compile_stdout = new AsyncInput(_compile_process.stdout);
        } else {
          if (_runCommand!=null) {
            do_run();
          } else {
            // TODO: terminatedevent...
            log("Compile, but no runCommand, TODO: terminate...");
            success = false;
            response.message = "No compileCmd or runCommand found.";
          }
        }

        response.success = success;
        send_response(response);
      }

      case "setExceptionBreakpoints": {
        //{"type":"request","seq":3,"command":"setExceptionBreakpoints","arguments":{"filters":["uncaught"]}}
        _exception_breakpoints_args = request.arguments;
        response.success = true;
        send_response(response);
      }

      case "setBreakpoints": {
        //{"type":"request","seq":3,"command":"setBreakpoints","arguments":{"source":{"path":"/home/jward/dev/vscode-hxcpp-debug/test openfl/Source/Main.hx"},"lines":[17]}}
        // TODO: set breakpoints in hxcpp-debugger
        response.success = true;
        var breakpoints = [];
        for (line in (request.arguments.lines:Array<Int>)) {
          breakpoints.push({ verified:true, line:line});
        }
        response.body = { breakpoints:breakpoints }
        send_response(response);
      }

      case "disconnect": {
        // TODO: restart?
        do_disconnect();
      }

      case "threads": {
        _debugger_commands.add(WhereAllThreads);
        _pending_responses.push(response);
      }

      case "stackTrace": {
        var stackFrames = ThreadsStopped.last.thread_stacks[request.arguments.threadId].concat([]);
        while (stackFrames.length>(request.arguments.levels:Int)) stackFrames.pop();
        response.body = {
          stackFrames:stackFrames.map(StackFrame.toVSCStackFrame)
        }
        response.success = true;
        send_response(response);
      }

      case "scopes": {
        var frameId = request.arguments.frameId;
        var frame = ThreadsStopped.last.getStackFrameById(frameId);

        // A scope of locals for each stackFrame
        response.body = {
          scopes:[{name:"Locals", variablesReference:frame.variablesReference, expensive:false}]
        }
        response.success = true;
        send_response(response);
      }

      case "variables": {
        var ref_idx:Int = request.arguments.variablesReference;
        var var_ref = ThreadsStopped.last.var_refs[ref_idx];

        if (var_ref==null) {
          log("variables requested for unknown variablesReference: "+ref_idx);
          response.success = false;
          send_response(response);
          return;
        }

        var stacks:Array<Array<StackFrame>> = ThreadsStopped.last.thread_stacks;
        var frame:StackFrame = var_ref.root;
        var thread_num = ThreadsStopped.last.threadNumForStackFrame(frame);
        _debugger_commands.add(SetCurrentThread(thread_num));

        log("Setting thread num: "+thread_num+", ref "+ref_idx+" out of "+ThreadsStopped.last.var_refs.length);

        if (Std.is(var_ref, StackFrame)) {
          //log("variables requested for StackFrame: "+haxe.format.JsonPrinter.print(frame));
          current_parent = var_ref;
          _debugger_commands.add(SetFrame(frame.number));
          _debugger_commands.add(Variables(false));
          _pending_responses.push(response);
        } else {
          current_parent = var_ref;
          var v:Variable = cast(var_ref);
          log("sub-variables requested for Variable: "+v.fq_name+":"+v.type);
          current_fqn = v.fq_name;
          outstanding_variables_cnt = 0;
          outstanding_variables = new StringMap<Variable>();

          if (v.type.indexOf("Array")>=0) {
            var r = ~/>\[(\d+)/;
            if (r.match(v.type)) {
              var length = Std.parseInt(r.matched(1));
              // TODO - max???
              for (i in 0...length) {
                _debugger_commands.add(PrintExpression(false, current_fqn+'['+i+']'));
                outstanding_variables_cnt++;
                var name:String = i+'';
                var v = new Variable(name, current_parent, true);
                outstanding_variables.set(name, v);
              }
            } else {
              // Array, length 0 or unknown
              current_fqn = null;
              outstanding_variables_cnt = 0;
              outstanding_variables = null;
              response.success = true;
              response.body = { variables:[] };
              send_response(response);
              return;
            }
          } else {
            var params:Array<String> = v.value.split("\n");
            for (p in params) {
              var idx = p.indexOf(" : ");
              if (idx>=0) {
                var name:String = StringTools.ltrim(p.substr(0, idx));
                _debugger_commands.add(PrintExpression(false,
                  current_fqn+'.'+name));
                outstanding_variables_cnt++;
                var v = new Variable(name, current_parent);
                outstanding_variables.set(name, v);
                log("Creating outstanding named '"+name+"', fq="+v.fq_name);
              }
            }
          }
          _pending_responses.push(response);
        }
      }

      // next
      // stepIn
      // stepOut
      // pause
      // continue

      default: {
        log("====== UNHANDLED COMMAND: "+command);
      }
    }
  }

  function do_run() {
    log("Starting VSCHaxeServer port 6972...");
    _vsc_haxe_server = Thread.create(start_server);
    _vsc_haxe_server.sendMessage(log);
    _vsc_haxe_server.sendMessage(_debugger_messages);
    _vsc_haxe_server.sendMessage(_debugger_commands);

    log("Launching application...");
    send_output("Launching application...");

    _run_process = start_process(_runCommand, _runPath, _runInTerminal);

    // Wait for debugger to connect... TODO: timeout?
    _sent_initialized = false;
  }

  function read_compile() {
    // TODO: non-blocking compile process, send stdout as we receive it,
    // handle disconnect
 
    // Blocks until complete:

    var line:StringBuf = new StringBuf();
    var compile_finished:Bool = false;
    while (_compile_stdout.hasData()) {
      try {
        line.addChar(_compile_stdout.readByte());
      } catch (e : haxe.io.Eof) {
        compile_finished = true;
        break;
      }
    }
    if (_compile_stdout.isClosed()) compile_finished = true;

    //var output = compile_process.stdout.readAll();
    var result = line.toString();
    result = (~/\x1b\[[0-9;]*m/g).replace(result, "");

    if (result.length>0) {
      log(result);
      send_output(result, 'console', false);
    }

    if (compile_finished) {
      var success = _compile_process.exitCode()==0;
      log("Compile "+(success ? "succeeded!" : "FAILED!"));
      send_output("Compile "+(success ? "succeeded!" : "FAILED!"));
      _compile_process = null;
      _compile_stdout = null;

      if (success) {
        do_run();
      } else {
        do_disconnect();
      }
    }

  }

  function do_disconnect(send_message:Bool=false):Void
  {
    if (_run_process!=null) {
      log("Killing _run_process");
      _run_process.close();
      _run_process.kill(); // TODO, this is not closing the app
      _run_process = null;
    }
    if (_compile_process!=null) {
      log("Killing _compile_process");
      _compile_process.close();
      _compile_process.kill(); // TODO, this is not closing the process
      _compile_process = null;
    }
    if (send_message) {
      log("Sending disconnect message to VSCode");
      send_response({"type":"request","seq":1,"command":"disconnect","arguments":{"extensionHostData":{"restart":false}}});
    }
    log("Disconnecting...");
    Sys.exit(0);
  }

  function start_process(cmd:String, path:String, in_terminal:Bool=false):Process
  {
    var old:String = null;
    if (in_terminal) {
      cmd = "gnome-terminal --working-directory="+path.split(" ").join('\\ ')+" -x ./"+cmd.split(" ").join('\\ ');
    } else {
      old = Sys.getCwd();
      Sys.setCwd(path);
    }
    log("cmd: "+cmd);
    var args = split_args(cmd);
    log("args: "+args.join('|'));
    var display = args.join(" ");
    cmd = args.shift();

    // TODO: file separator for windows? Maybe not necessary for windows
    // as ./ is in the PATH by default?
    if (sys.FileSystem.exists(path+'/'+cmd)) {
      log("Setting ./ prefix");
      cmd = "./"+cmd;
    }

    var proc = new sys.io.Process(cmd, args);
    log("Starting: "+display+", pid="+proc.getPid());
    if (old!=null) Sys.setCwd(old);
    return proc;
  }

  static function start_server():Void
  {
    var log:String->Void = Thread.readMessage(true);
    var messages:Deque<Message> = Thread.readMessage(true);
    var commands:Deque<Command> = Thread.readMessage(true);
    var vschs = new debugger.VSCHaxeServer(log, commands, messages);
    // fyi, the above constructor function does not return
  }

  var current_parent:IVarRef;
  var current_fqn:String;
  var outstanding_variables:StringMap<Variable>;
  var outstanding_variables_cnt:Int = 0;

  function check_pending(command:String):Dynamic
  {
    var remove:Dynamic = null;
    for (i in _pending_responses) {
      if (i.command==command) {
        remove = i;
        break;
      }
    }
    if (remove!=null) {
      _pending_responses.remove(remove);
    }
    return remove;
  }

  function check_finished_variables():Void
  {
    if (outstanding_variables_cnt==0) {
      var response:Dynamic = check_pending("variables");
      var variables = [];
      for (name in outstanding_variables.keys()) {
        variables.push(outstanding_variables.get(name));
      }
      response.body = { variables: variables.map(Variable.toVSCVariable) };

      outstanding_variables = null;
      current_fqn = null;
      response.success = true;
      send_response(response);
    }
  }

  function check_debugger_messages():Void
  {
    var message:Message = _debugger_messages.pop(false);

    if (message==null) return;

    log("Got message: "+message);

    // The first OK indicates a connection with the debugger
    if (message==OK && _sent_initialized == false) {
      _sent_initialized = true;
      send_event({"event":"initialized"});
      return;
    }

    switch (message) {

    case ThreadStopped(number, frameNumber, className, functionName,
                       fileName, lineNumber):
      log("\nThread " + number + " stopped in " +
          className + "." + functionName + "() at " +
          fileName + ":" + lineNumber + ".");

      send_event({"event":"stopped", "body":{"reason":"entry","threadId":number}});

    case ThreadsWhere(list):
      new ThreadsStopped(); // catches new AppThread(), new StackFrame()
      while (true) {
        switch (list) {
        case Terminator:
          break;
        case Where(number, status, frameList, next):
          new AppThread(number);
          //Sys.print("Thread " + number + " (");
          var isRunning : Bool = false;
          switch (status) {
          case Running:
            //Sys.println("running)");
            list = next;
            isRunning = true;
          case StoppedImmediate:
            //Sys.println("stopped):");
          case StoppedBreakpoint(number):
            //Sys.println("stopped in breakpoint " + number + "):");
          case StoppedUncaughtException:
            //Sys.println("uncaught exception):");
          case StoppedCriticalError(description):
            //Sys.println("critical error: " + description + "):");
          }
          var hasStack = false;
          while (true) {
            switch (frameList) {
            case Terminator:
              break;
            case Frame(isCurrent, number, className, functionName,
                       fileName, lineNumber, next):
              //Sys.print((isCurrent ? "* " : "  "));
              //Sys.print(padStringRight(Std.string(number), 5));
              //Sys.print(" : " + className + "." + functionName +
              //          "()");
              //Sys.println(" at " + fileName + ":" + lineNumber);
              new StackFrame(number, className, functionName, fileName, lineNumber);
              hasStack = true;
              frameList = next;
            }
          }
          if (!hasStack && !isRunning) {
            //Sys.println("No stack.");
          }
          list = next;
        }
      }

      ThreadsStopped.last.var_refs.push(null); // 1-indexed
      for (thread_stack_frames in ThreadsStopped.last.thread_stacks) {
        for (stack_frame in thread_stack_frames) {
          ThreadsStopped.last.var_refs.push(stack_frame);
          stack_frame.variablesReference = ThreadsStopped.last.var_refs.length-1;
        }
      }

      var response:Dynamic = check_pending("threads");
      response.body = {threads: ThreadsStopped.last.threads.map(AppThread.toVSCThread)};
      response.success = true;
      send_response(response);

    // Only occurs when requesting variables (names) from a frame
    case Variables(list):
      if (!Std.is(current_parent, StackFrame)) do_throw("Error, current_parent should be a StackFrame!");
      if (outstanding_variables!=null) do_throw("Error, variables collision!");
      outstanding_variables = new StringMap<Variable>();
      outstanding_variables_cnt = 0;

      while (true) {
        switch (list) {
        case Terminator:
          break;
        case Element(name, next):
          var v = new Variable(name, current_parent);
          outstanding_variables.set(name, v);
          _debugger_commands.add(PrintExpression(false, v.name));
          list = next;
          outstanding_variables_cnt++;
        }
      }

      // No variables?
      if (outstanding_variables_cnt==0) check_finished_variables();

    case Value(expression, type, value):
      //Sys.println(expression + " : " + type + " = " + value);
      if (current_fqn==null) {
        var v:Variable = outstanding_variables.get(expression);
        v.assign(type, value);
        log("Variable: "+v.fq_name+" assigned variablesReference "+v.variablesReference);
      } else {
        log("Got FQ["+current_fqn+"] value: "+message);
        var name = expression.substr(current_fqn.length+1);
        // TODO: Array, 1]
        var v:Variable = outstanding_variables.get(name);
        if (v!=null) {
          v.assign(type, value);
        } else {
          log("Uh oh, didn't find variable named: "+name);
        }
      }
      outstanding_variables_cnt--;
      check_finished_variables();

    case ErrorEvaluatingExpression(details):
      //Sys.println(expression + " : " + type + " = " + value);
      log("Error evaluating expression: "+details);
      outstanding_variables_cnt--;
      check_finished_variables();

    default:
    }
  }
}

class StackFrame implements IVarRef {

  //static var instances:Array<StackFrame> = [];

  public var number(default, null):Int;
  public var className(default, null):String;
  public var functionName(default, null):String;
  public var fileName(default, null):String;
  public var lineNumber(default, null):Int;
  public var id(default, null):Int;

  public var variablesReference(default, default):Int;

  public var parent:IVarRef;
  public var root(get, null):StackFrame;
  public function get_root():StackFrame
  {
    return cast(this);
  }

  public function new(number:Int,
                      className:String,
                      functionName:String,
                      fileName:String,
                      lineNumber:Int)
  {
    this.number = number;
    this.className = className;
    this.functionName = functionName;
    this.fileName = fileName;
    this.lineNumber = lineNumber;

    root = this;

    this.id = ThreadsStopped.last.register_stack_frame(this);
  }

  public static function toVSCStackFrame(s:StackFrame):Dynamic
  {
    return {
      name:s.className+'.'+s.functionName,
      source:s.fileName,
      line:s.lineNumber,
      column:0,
      id:s.id
    }
  }

  //public static function lookup(number:Int,
  //                              className:String,
  //                              functionName:String,
  //                              fileName:String,
  //                              lineNumber:Int):StackFrame
  //{
  //  for (s in instances)
  //    if (s.number==number &&
  //        s.className==className &&
  //        s.functionName==functionName &&
  //        s.fileName==fileName &&
  //        s.lineNumber==lineNumber) return s;
  // 
  //  var s = new StackFrame(number,
  //                         className,
  //                         functionName,
  //                         fileName,
  //                         lineNumber);
  //  s.id = instances.length;
  //  instances.push(s);
  //  return s;
  //}
}

class Variable implements IVarRef {

  public var name(default, null):String;
  public var value(default, null):String;
  public var type(default, null):String;

  public var variablesReference(default, null):Int = 0;
  var is_decimal = false;

  public function new(name:String, parent:IVarRef, decimal:Bool=false) {
    this.name = name;
    this.parent = parent;
    is_decimal = decimal;
  }

  public var parent:IVarRef;
  public var root(get, null):StackFrame;
  public function get_root():StackFrame
  {
    var p:IVarRef = parent;
    while (p.parent!=null) p = p.parent;
    return cast(p);
  }

  public var fq_name(get, null):String;
  public function get_fq_name():String
  {
    var fq = name;
    if (Std.is(parent, Variable)) {
      fq = cast(parent, Variable).fq_name+(is_decimal ? '['+name+']' : '.'+name);
    }
    return fq;

    var parent = parent;
    while (parent!=null && Std.is(parent, Variable)) {
      fq = cast(parent, Variable).name+'.'+fq;
    }
    return fq;
  }

  public function assign(type:String, value:String):Void
  {
    if (this.type!=null) DebugAdapter.do_throw("Variable can only be assigned once");
    this.type = type;
    this.value = value;

    if (SIMPLES.indexOf(type)<0) {
      ThreadsStopped.last.var_refs.push(this);
      variablesReference = ThreadsStopped.last.var_refs.length-1;
    }
  }

  private static var SIMPLES:Array<String> = ["String", "NULL", "Bool", "Int", "Float",
                                              "Anonymous", "Function"
                                             ];
  public static function toVSCVariable(v:Variable):Dynamic {
    return {
      name:v.name,
      value:v.variablesReference==0 ? (v.value==null ? "--DebugEvalError--" : v.value) : "["+v.type+"]",
      variablesReference:v.variablesReference
    };
  }
}

interface IVarRef {
  public var parent:IVarRef;
  public var root(get, null):StackFrame;
}

class AppThread {
  public var id:Int;
  public function new(id:Int) {
    this.id = id;
    ThreadsStopped.last.register_app_thread(this);
  }
  public static function toVSCThread(t:AppThread) { return { id:t.id, name:"Thread #"+t.id }; }
}

class ThreadsStopped {
  public static var last:ThreadsStopped;

  public var threads:Array<AppThread>;
  public var thread_stacks:Array<Array<StackFrame>>;
  public var var_refs:Array<IVarRef>;

  public function new()
  {
    this.threads = [];
    this.thread_stacks = [];
    this.var_refs = [];

    last = this;
  }

  public function getStackFrameById(frameId:Int):StackFrame
  {
    for (stack in thread_stacks) {
      if (frameId > stack.length) {
        frameId -= stack.length;
      } else {
        return stack[frameId];
      }
    }
    return null;
  }

  public function threadNumForStackFrame(frame:StackFrame):Int
  {
    for (thread_num in 0...threads.length) {
      for (stack_frame in thread_stacks[thread_num]) {
        if (frame==stack_frame) {
          return thread_num;
        }
      }
    }
    return 0;
  }

  public function register_app_thread(t:AppThread):Void
  {
    threads.push(t);
    thread_stacks.push(new Array<StackFrame>());
  }

  private var total_stack_frames:Int = 0;
  public function register_stack_frame(frame:StackFrame):Int
  {
    var val = total_stack_frames++;
    thread_stacks[thread_stacks.length-1].push(frame);
    var_refs.push(frame);
    return val;
  }
}

