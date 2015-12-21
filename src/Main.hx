package;

import haxe.io.Input;
import haxe.io.Output;
import haxe.io.Bytes;
import haxe.io.Path;

import sys.FileSystem;

import haxe.ds.StringMap;
import haxe.ds.IntMap;

import sys.io.Process;

import cpp.vm.Thread;
import cpp.vm.Deque;
import cpp.vm.Mutex;

import debugger.IController;

class Main {
  static function main() {
    // new debugger.HaxeRemote(true, "localhost", 7001);
    var log:Output = null;
    if (sys.FileSystem.isDirectory("/tmp")) {
      log = sys.io.File.append("/tmp/adapter.log", false);
    }
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

  var _compile_process:Process;
  var _compile_stdout:AsyncInput;
  var _compile_stderr:AsyncInput;

  var _runCommand:String = null;
  var _runPath:String = null;
  var _runInTerminal:Bool = false;
  var _run_process:Process;

  var _warn_timeout:Float = 0;

  var _server_initialized:Bool = false;
  var _first_stopped:Bool = false;
  var _send_stopped:Array<Int> = [];

  var _vsc_haxe_server:Thread;
  var _debugger_messages:Deque<Message>;
  var _debugger_commands:Deque<Command>;
  var _pending_responses:Array<Dynamic>; 
  var _run_exit_deque:Deque<Int>;

  public function new(i:Input, o:Output, log_o:Output) {
    _input = new AsyncInput(i);
    _output = o;
    _log = log_o;
    _log_mutex = new Mutex();

    _debugger_messages = new Deque<Message>();
    _debugger_commands = new Deque<Command>();
    _run_exit_deque = new Deque<Int>();

    _pending_responses = [];
    while (true) {
      if (_input.hasData() && outstanding_variables==null) read_from_vscode();
      if (_compile_process!=null) read_compile();
      if (_run_process!=null) check_debugger_messages();
      if (_warn_timeout>0 && Sys.time()>_warn_timeout) {
        _warn_timeout = 0;
        log("Client not yet connected, does it call new HaxeRemote(true, 'localhost') ?");
        send_output("Client not yet connected, does it call new HaxeRemote(true, 'localhost') ?");
      }
      // Grr, this is dying instantly... gnome-terminal layer closes :(
      // var exit:Null<Int> = _run_exit_deque.pop(false);
      // if (exit != null) {
      //   log("Client app process exited: "+exit);
      //   send_output("Client app process exited: "+exit);
      //   do_disconnect();
      // }
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
    if (_log!=null) {
      _log.writeString(Sys.time()+": "+s+"\n");
      _log.flush();
    }
    _log_mutex.release();
  }

  function burn_blank_line():Void
  {
    var b:Int;
#if windows
    if ((b=_input.readByte())!=10) log("Protocol error, expected 10, got "+b);
#else
    if ((b=_input.readByte())!=13) log("Protocol error, expected 13, got "+b);
    if ((b=_input.readByte())!=10) log("Protocol error, expected 10, got "+b);
#end
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
#if windows
    _output.writeByte(10);
    _output.writeByte(10);
#else
    _output.writeByte(13);
    _output.writeByte(10);
    _output.writeByte(13);
    _output.writeByte(10);
#end
    _output.writeBytes(b, 0, b.length);
    _output.flush();
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
        _launch_req = request;
        SourceFiles.proj_dir = _launch_req.arguments.cwd;
        log("Launching... proj_dir="+SourceFiles.proj_dir);
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
          _compile_stderr = new AsyncInput(_compile_process.stderr);
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

      // TODO: implement pause on exceptions on debugger side
      // case "setExceptionBreakpoints": {
      //   //{"type":"request","seq":3,"command":"setExceptionBreakpoints","arguments":{"filters":["uncaught"]}}
      //   _exception_breakpoints_args = request.arguments;
      //   response.success = true;
      //   send_response(response);
      // }

      case "setBreakpoints": {
        process_set_breakpoints(request);
      }

      case "disconnect": {
        // TODO: restart?
        response.success = true;
        send_response(response);
        do_disconnect(false);
      }

      case "threads": {
        // ThreadStatus was just populated by stopped event
        //response.body = {threads: ThreadStatus.last.threads.map(AppThreadStoppedState.toVSCThread)};
        response.body = {threads: ThreadStatus.live_threads.map(AppThreadStoppedState.idToVSCThread)};
        response.success = true;
        send_response(response);
      }

      case "stackTrace": {
        var stackFrames = ThreadStatus.by_id(request.arguments.threadId).stack_frames.concat([]);
        while (stackFrames.length>(request.arguments.levels:Int)) stackFrames.pop();
        response.body = {
          stackFrames:stackFrames.map(StackFrame.toVSCStackFrame)
        }
        response.success = true;
        send_response(response);
      }

      case "scopes": {
        var frameId = request.arguments.frameId;
        var frame = ThreadStatus.getStackFrameById(frameId);

        // A scope of locals for each stackFrame
        response.body = {
          scopes:[{name:"Locals", variablesReference:frame.variablesReference, expensive:false}]
        }
        response.success = true;
        send_response(response);
      }

      case "variables": {
        var ref_idx:Int = request.arguments.variablesReference;
        var var_ref = ThreadStatus.var_refs.get(ref_idx);

        if (var_ref==null) {
          log("variables requested for unknown variablesReference: "+ref_idx);
          response.success = false;
          send_response(response);
          return;
        }

        var frame:StackFrame = var_ref.root;
        var thread_num = ThreadStatus.threadNumForStackFrameId(frame.id);
        _debugger_commands.add(SetCurrentThread(thread_num));

        log("Setting thread num: "+thread_num+", ref "+ref_idx);

        if (Std.is(var_ref, StackFrame)) {
          log("variables requested for StackFrame: "+frame.fileName+':'+frame.lineNumber);
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

      case "continue": {
        _debugger_commands.add(Continue(1));
        _pending_responses.push(response);

        // response.success = true;
        // _debugger_commands.add(Continue(1));
        // // TODO: wait for ThreadStarted message
        // send_response(response);
      }

      case "pause": {
        _debugger_commands.add(BreakNow);
        _pending_responses.push(response);
      }

      case "next": {
        _debugger_commands.add(Next(1));
        response.success = true;
        send_response(response);
      }

      case "stepIn": {
        _debugger_commands.add(Step(1));
        response.success = true;
        send_response(response);
      }

      case "stepOut": {
        _debugger_commands.add(Finish(1));
        response.success = true;
        send_response(response);
      }

      // evaluate == watch

      default: {
        log("====== UNHANDLED COMMAND: "+command);
      }
    }
  }

  function process_set_breakpoints(request:Dynamic)
  {
    var response:Dynamic = {
      request_seq:request.seq,
      command:request.command,
      success:true
    }

    //{"type":"request","seq":3,"command":"setBreakpoints","arguments":{"source":{"path":"/home/jward/dev/vscode-hxcpp-debug/test openfl/Source/Main.hx"},"lines":[17]}}
    var file:String = SourceFiles.getDebuggerFilename(request.arguments.source.path);
    log("Setting breakpoints in:");
    log(" VSC: "+request.arguments.source.path);
    log(" DBG: "+file);

    // It doesn't seem hxcpp-debugger corrects/verifies line
    // numbers, so just pass these back as verified
    var breakpoints = [];
    for (line in (request.arguments.lines:Array<Int>)) {
      _debugger_commands.add(AddFileLineBreakpoint(file, line));

      breakpoints.push({ verified:true, line:line});
    }
    response.body = { breakpoints:breakpoints }
    send_response(response);
  }

  function do_run() {
    log("Starting VSCHaxeServer port 6972...");
    _vsc_haxe_server = Thread.create(start_server);
    _vsc_haxe_server.sendMessage(log);
    _vsc_haxe_server.sendMessage(_debugger_messages);
    _vsc_haxe_server.sendMessage(_debugger_commands);

    if (!FileSystem.isDirectory(_runPath)) {
      log("Error: runPath not found: "+_runPath);
      send_output("Error: runPath not found: "+_runPath);
      do_disconnect();
      return;
    }

    var exec = Path.normalize(_runPath+'/'+_runCommand);
    if (!FileSystem.exists(exec)) {
      if (FileSystem.exists(exec+".exe")) {
        _runCommand += '.exe';
      } else {
        log("Error: runCommand not found: "+exec);
        send_output("Error: runCommand not found: "+exec);
        do_disconnect();
        return;
      }
    }

    log("Launching application...");
    send_output("Launching application...");

    _run_process = start_process(_runCommand, _runPath, _runInTerminal);
    var t = Thread.create(monitor_run_process);
    t.sendMessage(_run_exit_deque);
    t.sendMessage(_run_process);

    _warn_timeout = Sys.time()+3;

    // Wait for debugger to connect... TODO: timeout?
    _server_initialized = false;
  }

  function read_compile() {
    // TODO: non-blocking compile process, send stdout as we receive it,
    // handle disconnect

    var line:StringBuf = new StringBuf();
    var compile_finished:Bool = false;

    while (_compile_stderr.hasData()) {
      try {
        line.addChar(_compile_stderr.readByte());
      } catch (e : haxe.io.Eof) {
        break;
      }
    }

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
      log("Compiler: "+result);
      send_output(result, 'console', false);
    }

    if (compile_finished) {

      var success = _compile_process.exitCode()==0;
      log("Compile "+(success ? "succeeded!" : "FAILED!"));
      send_output("Compile "+(success ? "succeeded!" : "FAILED!"));
      _compile_process = null;
      _compile_stdout = null;
      _compile_stderr = null;

      if (success) {
        do_run();
      } else {
        do_disconnect();
      }
    }

  }

  function do_disconnect(send_exited:Bool=true):Void
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
    if (send_exited) {
      log("Sending exited event to VSCode");
      send_event({"event":"terminated"});
    } // else { hmm, is there a disconnect event we can send? }
    log("Disconnecting...");
    Sys.exit(0);
  }

  function start_process(cmd:String, path:String, in_terminal:Bool=false):Process
  {
    var old:String = null;
    if (in_terminal) {
#if mac
      // Create /tmp/run, run "open /tmp/run"
      var run = sys.io.File.write("/tmp/run", false);
      run.writeString("cd "+path.split(" ").join('\\ ')+"; ./"+cmd.split(" ").join('\\ '));
      run.flush(); run.close();
      Sys.command("chmod", ["a+x", "/tmp/run"]);
      cmd = "open /tmp/run";
#elseif linux
      // TODO: optional terminal command (for non-gnome-terminal/ubuntu)
      cmd = "gnome-terminal --working-directory="+path.split(" ").join('\\ ')+" -x ./"+cmd.split(" ").join('\\ ');
#elseif windows
      // Hmm, this should work but doesn't...
      // cmd = "start /wait cmd /C \"cd "+path+" && "+cmd+"\"";
      send_output("Error: runInTerminal not yet supported in Windows...");
#end
    } else {
      old = Sys.getCwd();
      Sys.setCwd(path);
    }
    log("cmd: "+cmd);
    var args = split_args(cmd);
    log("args: "+args.join('|'));
    var display = args.join(" ");
    cmd = args.shift();

    // ./ as current directory isn't typically in PATH
    // Shouldn't be necessary for windows as the current directory
    // is in the PATH by default... I think.
#if (!windows)
    if (sys.FileSystem.exists(path+SourceFiles.SEPARATOR+cmd)) {
      log("Setting ./ prefix");
      cmd = "./"+cmd;
    }
#end

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

  static function monitor_run_process() {
    var dq:Deque<Int> = Thread.readMessage(true);
    var proc:Process = Thread.readMessage(true);
    
    log("PM: Monitoring process: "+proc.getPid());
    var exit = proc.exitCode();
    log("PM: Detected process exit: "+exit);

    dq.push(exit);
  }
  var current_parent:IVarRef;
  var current_fqn:String;
  var outstanding_variables:StringMap<Variable>;
  var outstanding_variables_cnt:Int = 0;

  function has_pending(command:String):Bool
  {
    for (i in _pending_responses) {
      if (i.command==command) {
        return true;
      }
    }
    return false;
  }

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

    switch (message) {
    case Files(list):
      // Don't know why -- it hangs printing this message
      log("Got message: Files(...)");
    case Value(expression, type, value):
      // Too verbose, just expression and type
      log("Got message: Value("+expression+", "+type+", ...)");
    default:
      log("Got message: "+message);
    }

    // The first OK indicates a connection with the debugger
    if (message==OK && _server_initialized == false) {
      _warn_timeout = 0;
      _server_initialized = true;
      return;
    }

    switch (message) {

    case Files(list):
      log("Populating "+(SourceFiles.files==null ? "SourceFiles.files" : "SourceFiles.files_full"));
      var tgt:Array<String>;
      if (SourceFiles.files==null) {
        tgt = SourceFiles.files = [];
      } else {
        tgt = SourceFiles.files_full = [];
      }

      while (true) {
        switch (list) {
        case Terminator:
          break;
        case Element(name, next):
          if (name.indexOf("Main.hx")>=0) log("Push: "+name);
          tgt.push(name);
          list = next;
        }
      }

      // Send initialized after files have been queried, ready to
      // accept breakpoints
      if (tgt==SourceFiles.files_full) {
        send_event({"event":"initialized"});
      }

    case ThreadStarted(number):
      // respond to continue, if it was a continue
      var response:Dynamic = check_pending("continue");
      if (response!=null) {
        response.success = true;
        send_response(response);
      }

    case ThreadStopped(number, frameNumber, className, functionName,
                       fileName, lineNumber):
      log("\nThread " + number + " stopped in " +
          className + "." + functionName + "() at " +
          fileName + ":" + lineNumber + ".");

      // First time thread stopped, ask for files first
      if (!_first_stopped) {
        _first_stopped = true;
        _debugger_commands.add(Files);
        _debugger_commands.add(FilesFullPath);
      }

    //_debugger_commands.add(WhereAllThreads);
      _debugger_commands.add(SetCurrentThread(number));
      _debugger_commands.add(WhereCurrentThread(false));
      _send_stopped.push(number);

    case ThreadCreated(number):
      log("Thread " + number + " created.");
      if (ThreadStatus.live_threads.indexOf(number)>=0) {
        DebugAdapter.log("Error, thread "+number+" already exists");
      }
      ThreadStatus.live_threads.push(number);
      send_output("Thread " + number + " created.");
      send_event({"event":"thread", "body":{"reason":"started","threadId":number}});

    case ThreadTerminated(number):
      log("Thread " + number + " terminated.");
      if (ThreadStatus.live_threads.indexOf(number)<0) {
        DebugAdapter.log("Error, thread "+number+" doesn't exist");
      }
      ThreadStatus.live_threads.remove(number);
      send_output("Thread " + number + " terminated.");
      send_event({"event":"thread", "body":{"reason":"exited","threadId":number}});

    case ThreadsWhere(list):
      new ThreadStatus(); // catches new AppThreadStoppedState(), new StackFrame()
      while (true) {
        switch (list) {
        case Terminator:
          break;
        case Where(number, status, frameList, next):
          var t = new AppThreadStoppedState(number);

          // Respond to pause if there was one, then send stopped event
          var ssidx = _send_stopped.indexOf(number);
          if (ssidx>=0) {
            var stop_reason:String = has_pending("pause") ? "paused" : "entry";
            send_event({"event":"stopped", "body":{"reason":stop_reason,"threadId":number}});
            _send_stopped.remove(number);
          }

          var reason:String = "";
          var report_reason:Bool = false;
          reason += ("Thread " + number + " (");
          var isRunning : Bool = false;
          switch (status) {
          case Running:
            reason += ("running)\n");
            list = next;
            isRunning = true;
          case StoppedImmediate:
            reason += ("stopped):\n");
          case StoppedBreakpoint(number):
            reason += ("stopped in breakpoint " + number + "):\n");
          case StoppedUncaughtException:
            reason += ("uncaught exception):\n");
            report_reason = true;
          case StoppedCriticalError(description):
            reason += ("critical error: " + description + "):\n");
            report_reason = true;
          }
          var hasStack = false;
          while (true) {
            switch (frameList) {
            case Terminator:
              break;
            case Frame(isCurrent, number, className, functionName,
                       fileName, lineNumber, next):
              reason += ((isCurrent ? "* " : "  "));
              reason += (padStringRight(Std.string(number), 5));
              reason += (" : " + className + "." + functionName +
                         "()");
              reason += (" at " + fileName + ":" + lineNumber + "\n");
              new StackFrame(number, className, functionName, fileName, lineNumber);
              hasStack = true;
              frameList = next;
            }
          }
          if (!hasStack && !isRunning) {
            reason += ("No stack.\n");
          }
          if (report_reason) {
            log(StringTools.rtrim(reason));
            send_output(StringTools.rtrim(reason));
          }

          list = next;
        }
      }

      if (_send_stopped.length==0) {
        // no more stops pending? respond to pause, if it was a pause
        var response:Dynamic = check_pending("pause");
        if (response!=null) {
          response.success = true;
          send_response(response);
        }
      }

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

    case FileLineBreakpointNumber(number):
      log("Breakpoint " + number + " set and enabled.");

    default:
      log("====== UNHANDLED MESSAGE: "+message);
    }
  }

  private static function padStringRight(str : String, width : Int)
  {
    var spacesNeeded = width - str.length;

    if (spacesNeeded <= 0) {
      return str;
    }

    if (gEmptySpace[spacesNeeded] == null) {
      var str = "";
      for (i in 0...spacesNeeded) {
        str += " ";
      }
      gEmptySpace[spacesNeeded] = str;
    }

    return (gEmptySpace[spacesNeeded] + str);
  }
  private static var gEmptySpace : Array<String> = [ "" ];

}

class StackFrame implements IVarRef {

  //static var instances:Array<StackFrame> = [];

  public var number(default, null):Int;
  public var className(default, null):String;
  public var functionName(default, null):String;
  public var fileName(default, null):String;
  public var lineNumber(default, null):Int;
  public var id(default, null):Int;

  public var variablesReference:Int;

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

    this.id = ThreadStatus.register_stack_frame(this);
  }

  public static function toVSCStackFrame(s:StackFrame):Dynamic
  {

    // TODO: windows separator?
    return {
      name:s.className+'.'+s.functionName,
      source:SourceFiles.getVSCSource(s.fileName),
      line:s.lineNumber,
      column:0,
      id:s.id
    }
  }
}

class SourceFiles {

#if windows
  static public var SEPARATOR:String = "\\";
#else
  static public var SEPARATOR:String = '/';
#end

  public static var proj_dir:String = "";
  public static var files:Array<String> = null;
  public static var files_full:Array<String> = null;
  private static var _source_map:StringMap<String> = new StringMap<String>();

  public static function getVSCSource(source:String):Dynamic {
    if (!_source_map.exists(source)) {
      var idx:Int = files.indexOf(source);

      if (idx==-1) {
        for (ii in 0...files_full.length) {
          var f = files_full[ii]; // TODO: windows separator?
          if (StringTools.endsWith(f, SourceFiles.SEPARATOR+source)) {
            idx = ii;
            break;
          }
        }
      }

      var mapped:String = source;
      if (idx>=0) {
        mapped = files_full[idx];
        DebugAdapter.log("Found "+files_full[idx]+" for "+source);
      } else {
        DebugAdapter.log("NOT Found for "+source);
      }

      _source_map.set(source, mapped);
    }

    var f = _source_map.get(source);

    // { name:fileName, path:absPath }
    return { name:f.substr(f.lastIndexOf(SEPARATOR)), path:f };
  }

  private static var _back_map:StringMap<String> = new StringMap<String>();
  public static function getDebuggerFilename(vsc_filename:String):String
  {
    // TODO: this may not handle symlinks, as the debugger's full paths
    // have symlinks expanded.

    // Convert full path to the files[i] equivalent
    if (!_back_map.exists(vsc_filename)) {
      var idx:Int = files_full.indexOf(vsc_filename);
      _back_map.set(vsc_filename, idx>=0 ? files[idx] : vsc_filename);
    }
    return _back_map.get(vsc_filename);
  }
}

class Variable implements IVarRef {

  public var name(default, null):String;
  public var value(default, null):String;
  public var type(default, null):String;

  public var variablesReference:Int;
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
      ThreadStatus.register_var_ref(this);
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

// IVarRef, implemented by StackFrame and Variable
interface IVarRef {
  public var parent:IVarRef;
  public var root(get, null):StackFrame;
  public var variablesReference:Int;
}

class AppThreadStoppedState {
  public var id:Int;
  public var stack_frames:Array<StackFrame>;
  public function new(id:Int) {
    this.id = id;
    this.stack_frames = [];
    ThreadStatus.register_app_thread(this);
  }
  public static function toVSCThread(t:AppThreadStoppedState) { return { id:t.id, name:"Thread #"+t.id }; }
  public static function idToVSCThread(id:Int) { return { id:id, name:"Thread #"+id }; }
}

class ThreadStatus {
  public function new() { }

  // Managed by ThreadCreated and ThreadTerminated
  public static var live_threads:Array<Int> = [0];

  // Updated whenever thread stops
  public static var threads:IntMap<AppThreadStoppedState> = new IntMap<AppThreadStoppedState>();
  public static var var_refs:IntMap<IVarRef> = new IntMap<IVarRef>();
  private static var latest_thread_id:Int = 0;

  public static function by_id(id:Int):AppThreadStoppedState { return threads.get(id); }

  public static function getStackFrameById(frameId:Int):StackFrame
  {
    for (thread in threads.iterator()) {
      for (stack in thread.stack_frames) {
        if (stack.id==frameId) return stack;
      }
    }
    return null;
  }

  public static function threadNumForStackFrameId(frameId:Int):Int
  {
    for (thread in threads.iterator()) {
      for (stack in thread.stack_frames) {
        if (frameId==stack.id) return thread.id;
      }
    }
    DebugAdapter.log("Error, thread not found for frameId "+frameId);
    return -1;
  }

  public static function register_app_thread(t:AppThreadStoppedState):Void
  {
    latest_thread_id = t.id;
    if (threads.exists(t.id)) {
      // Dispose stack frames, var references, etc
      DebugAdapter.log("Disposing old thread "+t.id+" stack frames, etc");
      ThreadStatus.dispose_thread(threads.get(t.id));
    }
    threads.set(t.id, t);
  }

  private static var stack_frame_id_cnt:Int = 0;
  public static function register_stack_frame(frame:StackFrame):Int
  {
    var val = stack_frame_id_cnt++;
    threads.get(latest_thread_id).stack_frames.push(frame);
    register_var_ref(frame);
    return val;
  }

  private static var var_ref_id_cnt:Int = 0;
  public static function register_var_ref(iv:IVarRef):Void
  {
    var_ref_id_cnt++; // start at 1
    var_refs.set(var_ref_id_cnt, iv);
    iv.variablesReference = var_ref_id_cnt;
  }

  public static function dispose_thread(t:AppThreadStoppedState):Void
  {
    // Delete frame and all variables inside it?
    var rem_vars:Array<Int> = [];
    for (frame in t.stack_frames) {
      for (var_ref in var_refs.keys()) {
        var iv:IVarRef = var_refs.get(var_ref);
        if (iv==frame || iv.root==frame) rem_vars.push(var_ref);
      }
    }
    for (var_ref in rem_vars) {
      var_refs.remove(var_ref);
    }
    threads.remove(t.id);
  }
}

