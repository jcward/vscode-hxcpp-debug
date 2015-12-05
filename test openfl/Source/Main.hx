package;


import openfl.display.Bitmap;
import openfl.display.BitmapData;
import openfl.display.Sprite;
import openfl.Assets;

#if debug
import debugger.HaxeRemote;
#end

class Main extends Sprite {
	
	
	public function new () {
#if debug
    new debugger.HaxeRemote(true, "localhost");
    //new debugger.Local(true);
#end
		
		super ();
		
		var bitmap = new Bitmap (Assets.getBitmapData ("assets/openfl.png"));
		addChild (bitmap);
		
		bitmap.x = (stage.stageWidth - bitmap.width) / 2;
		bitmap.y = (stage.stageHeight - bitmap.height) / 2;
		
	}
	
	
}