package flixel.addons.ui;
import flash.display.BitmapData;
import flash.errors.Error;
import flash.geom.Matrix;
import flash.geom.Point;
import flash.geom.Rectangle;
import flash.Lib;
import flixel.addons.ui.FlxUI.MaxMinSize;
import flixel.addons.ui.ButtonLabelStyle;
import flixel.addons.ui.FlxUI.Operation;
import flixel.addons.ui.FlxUI.Rounding;
import flixel.addons.ui.FlxUI.VarValue;
import flixel.addons.ui.FlxUIBar.FlxBarStyle;
import flixel.addons.ui.FlxUICursor.WidgetList;
import flixel.addons.ui.FlxUIDropDownMenu;
import flixel.addons.ui.BorderDef;
import flixel.addons.ui.FlxUILine.LineAxis;
import flixel.addons.ui.FlxUIRadioGroup.CheckStyle;
import flixel.addons.ui.FlxUITooltipManager.FlxUITooltipData;
import flixel.addons.ui.FontDef;
import flixel.addons.ui.interfaces.IEventGetter;
import flixel.addons.ui.interfaces.IFireTongue;
import flixel.addons.ui.interfaces.IFlxUIButton;
import flixel.addons.ui.interfaces.IFlxUIClickable;
import flixel.addons.ui.interfaces.IFlxUIState;
import flixel.addons.ui.interfaces.IFlxUIText;
import flixel.addons.ui.interfaces.IFlxUIWidget;
import flixel.addons.ui.interfaces.IHasParams;
import flixel.addons.ui.interfaces.ILabeled;
import flixel.addons.ui.interfaces.IResizable;
import flixel.FlxG;
import flixel.FlxObject;
import flixel.FlxSprite;
import flixel.FlxState;
import flixel.group.FlxSpriteGroup;
import flixel.system.FlxAssets;
import flixel.text.FlxText;
import flixel.ui.FlxBar.FlxBarFillDirection;
import flixel.util.FlxArrayUtil;
import flixel.util.FlxColor;
import flixel.math.FlxPoint;
import flixel.util.FlxStringUtil;
import haxe.xml.Fast;
import openfl.Assets;
import openfl.text.TextFormat;

/**
 * A simple xml-driven user interface
 * 
 * Usage example:
 *	_ui = new FlxUI(U.xml("save_slot"),this);
 *	add(_ui);
 * 
 * @author Lars Doucet
 */

class FlxUI extends FlxUIGroup implements IEventGetter
{	
	
	//If this is true, the first few frames after initialization ignore all input so you can't auto-click anything
	public var do_safe_input_delay:Bool = true;
	public var safe_input_delay_time:Float = 0.01;
	
	public var failed:Bool = false;
	public var failed_by:Float = 0;
	
	/**
	 * Whether or not this UI is directly attached to the current top-most FlxState
	 */
	public var isRoot(get, null):Bool;
	private function get_isRoot():Bool { return _ptr != null && _ptr == getLeafUIState(); }
	
	//If you want to do live reloading, set the path to your assets directory on your local disk here, 
	//and it will load that instead of loading the xml specification from embedded assets
	//(only works on cpp/neko targets under debug mode)
	//this should serve as a PREFIX to the _xml_name:
	//if full path="path/to/assets/xml/ui/foo.xml" and _xml_name="ui/foo.xml", then liveFilePath="path/to/assets/xml/"
	public var liveFilePath:String;
	
	public var tongue(get, set):IFireTongue;
	private function get_tongue():IFireTongue { return _ptr_tongue; }
	private function set_tongue(t:IFireTongue):IFireTongue 
	{
		_ptr_tongue = t;
		_tongueSet(members, t);
		return _ptr_tongue;
	}
	
	public var focus(default, set):IFlxUIWidget;	//set focused object
	private function set_focus(widget:IFlxUIWidget):IFlxUIWidget {
		if (focus != null) {
			onFocusLost(focus);
		}
		focus = widget;
		if (focus != null) {
			onFocus(focus);
		}
		return widget;
	}
	
	//Set this 
	public var getTextFallback:String->String->Bool->String = null;
	
	/**
	 * Set this if you want to override setting case behavior (useful for dealing with locale edge cases)
	 */
	public static var formatFromCodeCallback:String->String->String = null;
	
	/**
	 * A useful hierarchical grouping of widgets for the FlxUICursor, null by default, populated during loading via xml:
		 * <cursor>
		 *   <list id="a,b,c"/>
		 *   <list id="d,e,f"/>
		 * </cursor>
	 */
	public var cursorLists(default, null):Array<Array<IFlxUIWidget>> = null;
	
	private var _ptr_tongue:IFireTongue;
	private var _data:Fast;
	
	/**
	 * Make sure to recursively propogate the tongue pointer down to all my members
	 */
	private function _tongueSet(list:Array<FlxSprite>, tongue:IFireTongue):Void 
	{		
		for (fs in list) {
			if (Std.is(fs, FlxUIGroup)) {
				var g:FlxUIGroup = cast(fs, FlxUIGroup);
				_tongueSet(g.members, tongue);
			}else if (Std.is(fs, FlxUI)) {
				var fu:FlxUI = cast(fs, FlxUI);
				fu.tongue = tongue;
			}
		}
	}
	
	/***EVENT HANDLING***/
	
	/**
	 * Broadcasts an event to the current FlxUIState/FlxUISubState
	 * @param	name	string identifier of the event -- each IFlxUIWidget has a set of string constants
	 * @param	sender	the IFlxUIWidget that sent this event
	 * @param	data	non-array data (boolean for a checkbox, string for a radiogroup, etc)
	 * @param	params	(optional) user-specified array of arbitrary data
	 */
	
	public static function event(name:String, sender:IFlxUIWidget, data:Dynamic, ?params:Array<Dynamic>):Void {
		var currState:IEventGetter = getLeafUIState();
		
		if (currState != null) {
			currState.getEvent(name, sender, data, params);
		}else {
			FlxG.log.notice("could not call getEvent() for FlxUI event \""+name+"\" because current state is not a FlxUIState.\nSolution: state should extend FlxUIState, implement IEventGetter. Otherwise, set broadcastToFlxUI=false for your IFlxUIWidget to supress the events.");
		}
	}
	
	/**
	 * Given something like "verdana" and "bold" returns "assets/fonts/verdanab"
	 * Also: checks Firetongue (if available) for font replacement rules
	 * @param	str
	 * @param	style
	 * @return
	 */
	public static inline function fontStr(str:String, style:String = ""):String
	{
		var t = __getTongue();
		if (t != null) { str = t.getFont(str); }
		return U.fontStr(str, style);
	}
	
	/**
	 * Given a font name & size, returns the correct size for that font in the current locale
	 * (Only really useful if you're using Firetongue with font replacement rules)
	 * @param	str
	 * @param	size
	 * @return
	 */
	public static function fontSize(str:String, size:Int):Int
	{
		var t = __getTongue();
		if (t != null) { size = t.getFontSize(str, size); }
		return size;
	}
	
	/**
	 * Given something like "verdana", "bold", ".ttf", returns "assets/fonts/verdanab.ttf"
	 * Also: checks Firetongue (if available) for font replacement rules
	 * @param	str
	 * @param	style
	 * @param	extension
	 * @return
	 */
 	public static function font(str:String, style:String = "", extension:String=".ttf"):String
	{
		var t = __getTongue();
		if (t != null) { str = t.getFont(str); }
		
		var result = U.font(str, style, extension);
		
		return result;
	}
	
	@:access(flixel.addons.ui.interfaces.IFlxUIState)
	private static inline function __getTongue():IFireTongue
	{
		var currState:IFlxUIState = getLeafUIState();
		if (currState == null) return null;
		var tongue:IFireTongue = currState._tongue;
		if (tongue != null)
		{
			return tongue;
		}
		return null;
	}
	
	/**
	 * Static-level function used to force giving a certain widget focus (useful for e.g. enforcing overlap logic)
	 * @param	b
	 * @param	thing
	 */
	public static function forceFocus(b:Bool, thing:IFlxUIWidget):Void 
	{
		var currState:IFlxUIState = getLeafUIState();
		if (currState != null) {
			currState.forceFocus(b, thing);				//this will try to drill down to currState._ui.onForceFocus()
		}
	}
	
	/**
	 * Drill down to the current state or sub-state, and ensure it is an IFlxUIState (FlxUIState or FlxUISubState)
	 * @return
	 */
	
	@:access(flixel.FlxState)
	public static function getLeafUIState():IFlxUIState{
		var state:FlxState = FlxG.state;
		if (state != null) 
		{
			while (state.subState != null && state._requestSubStateReset == false && Std.is(state.subState, IFlxUIState)) 
			{
				state = state.subState;
			}
		}
		if (Std.is(state, IFlxUIState)) 
		{
			return cast state;
		}
		return null;
	}
	
	/**
	 * Broadcasts an event to the current FlxUIState/FlxUISubState, and expects data in return
	 * @param	name	string identifier of the event -- each IFlxUIWidget has a set of string constants
	 * @param	sender	the IFlxUIWidget that sent this event
	 * @param	data	non-array data (boolean for a checkbox, string for a radiogroup, etc)
	 * @param	params	(optional) user-specified array of arbitrary data
	 * @return	some sort of arbitrary data from the recipient
	 */
	
	public static function request(name:String, sender:IFlxUIWidget, data:Dynamic, ?params:Array<Dynamic>):Dynamic {
		var currState:IEventGetter = getLeafUIState();
		if (currState != null) {
			return currState.getRequest(name, sender, data, params);
		}else {
			FlxG.log.error("Warning, FlxUI event not handled, IFlxUIWidgets need to exist within an IFlxUIState");
		}
		return null;
	}
	
	public function callEvent(name:String, sender:IFlxUIWidget, data:Dynamic, ?params:Array<Dynamic>):Void {
		getEvent(name, sender, data, params);
	}
	
	public function getEvent(name:String, sender:IFlxUIWidget, data:Dynamic, ?params:Array<Dynamic>):Void {
		if (_ptr != null)
		{
			_ptr.getEvent(name, sender, data, params);
			switch(name)
			{
				case "post_load": 
					for (key in _asset_index.keys())
					{
						var thing = _asset_index.get(key);
						if (Std.is(thing, FlxUI))
						{
							var fui:FlxUI = cast thing;
							fui.getEvent("post_load",sender,data);
						}
					}
			}
		}
	}
	
	public function getRequest(name:String, sender:IFlxUIWidget, data:Dynamic, ?params:Array<Dynamic>):Dynamic {
		if (_ptr != null) {
			return _ptr.getRequest(name, sender, data, params);
		}
		return null;
	}
		
	/***PUBLIC FUNCTIONS***/
	
	/**
	 * Creates a new FlxUI object
	 * @param	data			the xml layout for this UI
	 * @param	ptr				the object that receives events
	 * @param	superIndex_		(optional) another FlxUI object to search if assets are not found locally
	 * @param	tongue_			(optional) Firetongue object for localization
	 * @param	liveFilePath_	(optional) The path for live file loading (only works if debug && sys flags are true)
	 * @param	uiVars_			(optional) Any variables you want to pre-load the UI with
	 */
	
	public function new(data:Fast = null, ptr:IEventGetter = null, superIndex_:FlxUI = null, tongue_:IFireTongue = null, liveFilePath_:String="", uiVars_:Map<String,String>=null) 
	{
		super();
		_ptr_tongue = tongue_;	//set the localization data structure, if any.
								//we set this directly b/c no children have been created yet
								//when children FlxUI elements are added, this pointer is passed down
								//on destroy(), it is recurvisely removed from all of them
		#if (debug && sys)
			liveFilePath = liveFilePath_;	//set the path for live file loading (loads xml files from local disk rather than embedded assets. 
											//useful for faster edit-reload loop
		#end
		_ptr = ptr;
		if (superIndex_ != null) {
			setSuperIndex(superIndex_);
		}
		
		//if the state had variables for us, preload them now
		if (uiVars_ != null)
		{
			_variable_index = new Map<String,String>();
			for (key in uiVars_.keys())
			{
				_variable_index.set(key, uiVars_.get(key));
			}
		}
		
		if(data != null){
			load(data);
		}
		
		moves = false;
	}
	
	public function onFocus(widget:IFlxUIWidget):Void {
		if (Std.is(widget, FlxUIDropDownMenu)) {
			//when drop down menu has focus, every other button needs to skip updating
			for (asset in members){
				setWidgetSuppression(asset,widget);
			}
		}
	}
	
	private function setWidgetSuppression(asset:FlxSprite,butNotThisOne:IFlxUIWidget,suppressed:Bool=true):Void {
		if (Std.is(asset, IFlxUIClickable)) {
			var skip:Bool = false;
			if (Std.is(asset, FlxUIDropDownMenu)) {
				var ddasset:FlxUIDropDownMenu = cast asset;
				if (ddasset == butNotThisOne) {
					skip = true;
				}
			}
			if(!skip){
				var ibtn:IFlxUIClickable = cast asset;
				ibtn.skipButtonUpdate = suppressed;			//skip button updates until further notice
			}
		}else if (Std.is(asset, FlxUIGroup)) {
			var g:FlxUIGroup = cast asset;
			for (groupAsset in g.members) {
				setWidgetSuppression(groupAsset,butNotThisOne,suppressed);
			}
		}
	}
	
	/**
	 * This causes FlxUI to respond to a specific widget losing focus
	 * @param	widget
	 */
	
	public function onFocusLost(widget:IFlxUIWidget):Void {
		if (Std.is(widget, FlxUIDropDownMenu)) {
			//Right now, all this does is toggle button updating on and off for 
			
			//when drop down menu loses focus, every other button can resume updating
			for (asset in members) {
				setWidgetSuppression(asset, null, false);	//allow button updates again
			}
		}
	}
	
	/**
	 * Set a pointer to another FlxUI for the purposes of indexing
	 * @param	flxUI
	 */
	
	public function setSuperIndex(flxUI:FlxUI):Void {
		_superIndexUI = flxUI;
	}
	
	public override function update(elapsed:Float):Void {
		if (do_safe_input_delay) {
			_safe_input_delay_elapsed += FlxG.elapsed;
			if (_safe_input_delay_elapsed > safe_input_delay_time) {
				do_safe_input_delay = false;
			}else {
				return;
			}
		}
		super.update(elapsed);
	}
	
	public function toggleShow(key:String):Bool
	{
		var thing = getAsset(key, false);
		if (thing == null)
		{
			var group = getGroup(key, false);
			if (group != null)
			{
				group.visible = !group.visible;
				return group.visible;
			}
		}
		else
		{
			thing.visible = !thing.visible;
			return thing.visible;
		}
		return false;
	}
	
	public function showGroup(key:String, Show:Bool, ?Active:Null<Bool>=null):Void
	{
		var group = getGroup(key, false);
		if (group != null)
		{
			group.visible = Show;
			if (Active == null)
			{
				group.active = Show;
			}
			else
			{
				group.active = Active;
			}
		}
	}
	
	public function showAsset(key:String, Show:Bool, ?Active:Null<Bool>=null):Void
	{
		var asset = getAsset(key, false);
		if (asset != null) {
			asset.visible = Show;
			if (Active == null)
			{
				asset.active = Show;
			}
			else
			{
				asset.active = Active;
			}
		}
	}
	
	/**
	 * Removes an asset
	 * @param	key the asset to remove
	 * @param	destroy whether to destroy it
	 * @return	the asset, or null if destroy=true
	 */
	
	public function removeAsset(key:String, destroy:Bool = true):IFlxUIWidget {
		var asset = getAsset(key, false);
		if (asset != null) {
			replaceInGroup(cast asset, null, true);
			_asset_index.remove(key);
		}
		if (destroy && asset != null) {
			asset.destroy();
			asset = null;
		}
		return asset;
	}
	
	/**
	 * Adds an asset to this UI, and optionally puts it in a group
	 * @param	asset	the IFlxUIWidget asset you want to add
	 * @param	key		unique key for this asset. If it already exists, this fails.
	 * @param	group_name string name of group inside this FlxUI you want to add it to.
	 * @param	recursive whether to recursively search through sub-ui's
	 */
	
	public function addAsset(asset:IFlxUIWidget, key:String, group_name:String = "", recursive:Bool=false):Bool{
		if (_asset_index.exists(key))
		{
			if (key == "screen")
			{
				FlxG.log.notice("Failed to add a widget with the name 'screen', that is reserved by the system for the screen itself");
			}
			else
			{
				FlxG.log.notice("Duplicate screen name '" + key + "'");
			}
			return false;
		}
		
		var g:FlxUIGroup = getGroup(group_name,recursive);
		if (g != null)
		{
			g.add(cast asset);
		}
		else
		{
			add(cast asset);
		}
		
		_asset_index.set(key, asset);
		
		return true;
	}
	
	/**
	 * Replaces an asset, both in terms of location & group position
	 * @param	key the string name of the original
	 * @param	replace the replacement object
	 * @param 	destroy_old kills the original if true
	 * @return	the old asset, or null if destroy_old=true
	 */
	
	public function replaceAsset(key:String, replace:IFlxUIWidget, center_x:Bool=true, center_y:Bool=true, destroy_old:Bool=true):IFlxUIWidget{
		//get original asset
		var original = getAsset(key, false);
		
		if(original != null){
			//set replacement in its location
			if (!center_x) {
				replace.x = original.x;
			}else {
				replace.x = original.x + (original.width - replace.width) / 2;
			}
			if (!center_y) {
				replace.y = original.y;
			}else {
				replace.y = original.y + (original.height - replace.height) / 2;
			}
			
			//switch original for replacement in whatever group it was in
			replaceInGroup(cast original, cast replace);
			
			//remove the original asset index key
			_asset_index.remove(key);
			
			//key the replacement to that location
			_asset_index.set(key, replace);
			
			//destroy the original if necessary
			if (destroy_old) {
				original.destroy();
				original = null;
			}
		}
		
		return original;
	}
	
	
	/**
	 * Remove all the references and pointers, then destroy everything
	 */
	
	public override function destroy():Void {
		if(_group_index != null){
			for (key in _group_index.keys()) {
				_group_index.remove(key);
			}_group_index = null;
		}
		if(_asset_index != null){
			for (key in _asset_index.keys()) {
				_asset_index.remove(key);
			}_asset_index = null;
		}
		if(_tag_index != null){
			for (key in _tag_index.keys()) {
				FlxArrayUtil.clearArray(_tag_index.get(key));
				_tag_index.remove(key);
			}_tag_index = null;
		}
		if (_definition_index != null) {
			for (key in _definition_index.keys()) {
				_definition_index.remove(key);
			}_definition_index = null;
		}
		if (_variable_index != null) {
			for (key in _variable_index.keys()) {
				_variable_index.remove(key);
			}_variable_index = null;
		}
		if (_mode_index != null) {
			for (key in _mode_index.keys()) {
				_mode_index.remove(key);
			}_mode_index = null;
		}
		_ptr = null;
		_superIndexUI = null;
		_ptr_tongue = null;
		if (cursorLists != null)
		{
			for (arr in cursorLists)
			{
				FlxArrayUtil.clearArray(arr);
			}
			FlxArrayUtil.clearArray(cursorLists);
		}
		cursorLists = null;
		FlxArrayUtil.clearArray(_failure_checks); _failure_checks = null;
		FlxArrayUtil.clearArray(_assetsToCleanUp); _assetsToCleanUp = null;
		FlxArrayUtil.clearArray(_scaledAssets); _scaledAssets = null;
		super.destroy();
	}
	
	/**
	 * Main setup function - pass in a Fast(xml) object 
	 * to set up your FlxUI
	 * @param	data
	 */
	
	@:access(Xml)
	public function load(data:Fast):Void
	{
		_group_index = new Map<String,FlxUIGroup>();
		_asset_index = new Map<String,IFlxUIWidget>();
		_tag_index = new Map<String,Array<String>>();
		_definition_index = new Map<String,Fast>();
		if (_variable_index == null)
		{
			_variable_index = new Map<String,String>();
		}
		_mode_index = new Map<String,Fast>();
		
		if (data != null)
		{
			if (_superIndexUI == null)
			{
				//add a widget to represent the screen so you can do "screen.width", etc
				var screenRegion = new FlxUIRegion(0, 0, FlxG.width, FlxG.height);
				screenRegion.name = "screen";
				addAsset(screenRegion, "screen");
				
				if (data.hasNode.screen_override)
				{
					if(_loadTest(data.node.screen_override))
					{
						var screenNode = data.node.screen_override;
						_loadPosition(screenNode, screenRegion);
						screenRegion.width = _loadWidth(screenNode, FlxG.width);
						screenRegion.height = _loadHeight(screenNode, FlxG.height);
						
					}
				}
			}
			
			_data = data;
			
			data = resolveInjections(data);
			
			//See if there's anything to include
			if (data.hasNode.include)
			{
				for (inc_data in data.nodes.include)
				{
					var inc_name:String = U.xml_name(inc_data.x);
					
					var liveFile:Fast = null;
					
					#if (debug && sys)
						if (liveFilePath != null && liveFilePath != "")
						{
							try
							{
								liveFile = U.readFast(U.fixSlash(liveFilePath + inc_name + ".xml"));
							}
							catch (msg:String)
							{
								FlxG.log.warn(msg);
								liveFile = null;
							}
						}
					#end
					
					var inc_xml:Fast = null;
					if (liveFile == null)
					{
						inc_xml = getXML(inc_name);
					}
					else
					{
						inc_xml = liveFile;
					}
					
					if (inc_xml != null)
					{
						inc_xml = resolveInjections(inc_xml);
						
						for (def_data in inc_xml.nodes.definition)
						{
							if (_loadTest(def_data))
							{
								//add a prefix to avoid collisions:
								var def_name:String = "include:" + U.xml_name(def_data.x);
								
								unparentXML(def_data);
								
								_definition_index.set(def_name, def_data);
								//DON'T recursively search for further includes. 
								//Search 1 level deep only!
								//Ignore everything else in the include file
							}
						}
						
						if (inc_xml.hasNode.point_size)
						{
							_loadPointSize(inc_xml);
						}
						
						if (inc_xml.hasNode.resolve("default"))
						{
							for (defaultNode in inc_xml.nodes.resolve("default"))
							{
								if (_loadTest(defaultNode))
								{
									var defaultName:String = U.xml_name(defaultNode.x);
									
									unparentXML(defaultNode);
									
									_definition_index.set("default:" + defaultName, defaultNode);
								}
							}
						}
					}
				}
			}
			
			//First, see if we defined a point size
			
			if (data.hasNode.point_size)
			{
				_loadPointSize(data);
			}
			
			//Then, load all our definitions
			if (data.hasNode.definition)
			{
				for (def_data in data.nodes.definition)
				{
					if (_loadTest(def_data))
					{
						var def_name:String = U.xml_name(def_data.x);
						var error = "";
						if (def_name.indexOf("default:") != -1)
						{
							error = "'default:'";
						}
						if (def_name.indexOf("include:") != -1)
						{
							error = "'include:'";
						}
						if (error != "")
						{
							FlxG.log.warn("Can't create FlxUI definition '" + def_name + "', because '" + error + "' is a reserved name prefix!");
						}
						else
						{
							unparentXML(def_data);
							
							_definition_index.set(def_name, def_data);
						}
					}
				}
			}
			
			if (data.hasNode.resolve("default"))
			{
				for (defaultNode in data.nodes.resolve("default"))
				{
					if (_loadTest(defaultNode))
					{
						var defaultName:String = U.xml_name(defaultNode.x);
						
						unparentXML(defaultNode);
						
						_definition_index.set("default:" + defaultName, defaultNode);
					}
				}
			}
		
			//Next, load all our variables
			if (data.hasNode.variable)
			{
				for (var_data in data.nodes.variable)
				{
					if (_loadTest(var_data))
					{
						var var_name:String = U.xml_name(var_data.x);
						var var_value = U.xml_str(var_data.x, "value");
						if (var_name != "")
						{
							_variable_index.set(var_name, var_value);
						}
					}
				}
			}
		
			//Next, load all our modes
			if (data.hasNode.mode)
			{
				for (mode_data in data.nodes.mode)
				{
					if (_loadTest(mode_data))
					{
						var mode_data2:Fast = applyNodeConditionals(mode_data);
						var mode_name:String = U.xml_name(mode_data.x);
						//mode_data
						
						unparentXML(mode_data2);
						
						_mode_index.set(mode_name, mode_data2);
					}
				}
			}
			
			//Then, load all our group definitions
			if (data.hasNode.group)
			{
				for (group_data in data.nodes.group)
				{
					if (_loadTest(group_data))
					{
						//Create FlxUIGroup's for each group we define
						var name:String = U.xml_name(group_data.x);
						var custom:String = U.xml_str(group_data.x, "custom");
						
						var tempGroup:FlxUIGroup = null;
						
						//Allow the user to provide their own customized FlxUIGroup class
						if (custom != "")
						{
							var result = _ptr.getRequest("ui_get_group:", this, custom);
							if (result != null && Std.is(result, FlxUIGroup))
							{
								tempGroup = cast result;
							}
						}
						
						if(tempGroup == null)
						{
							tempGroup = new FlxUIGroup();
						}
						
						tempGroup.name = name;
						_group_index.set(name, tempGroup);
						add(tempGroup);
					}
				}
			}
			
			if (data.x.firstElement() != null)
			{
				//Load the actual things
				var node:Xml;
				for (node in data.x.elements()) 
				{
					_loadSub(node);
				}
			}
			
			_postLoad(data);
			
		}
		else {
			_onFinishLoad();
		}
	}
	
	@:access(Xml)
	private function resolveInjections(data:Fast):Fast
	{
		if (data.hasNode.inject)
		{
			while(data.hasNode.inject)
			{
				var inj_data = data.node.inject;
				
				var i = 0;
				var payload:Xml = null;
				var parent:Xml = inj_data.x.parent;
				
				if (_loadTest(inj_data))
				{
					var inj_name:String = U.xml_name(inj_data.x);
					payload = getXML(inj_name, "xml", false);
					
					for (child in parent.children)
					{
						if (child == inj_data.x)
						{
							break;
						}
						i++;
					}
				}
				
				if (parent.removeChild(inj_data.x))
				{
					if (payload != null)
					{
						var j:Int = 0;
						for (e in payload.elements())
						{
							parent.insertChild(e, i + j);
							j++;
						}
					}
				}
			}
		}
		return data;
	}
	
	private function unparentXML(f:Fast):Fast
	{
		return U.unparentXML(f);
	}
	
	private function _loadPointSize(data:Fast):Void
	{
		var ptx = -1.0;
		var pty = -1.0;
		
		for (node in data.nodes.point_size)
		{
			if (_loadTest(node))
			{
				ptx = _loadX(node, ptx);
				pty = _loadY(node, pty);
				
				//if neither x or y is defined look for a "value" parameter to set both
				if (pty < 1 && ptx < 1)
				{
					pty = _loadHeight(node, -1, "value");
					ptx = pty;
				}
			}
		}
		
		//if x or y is not defined default to 1
		if (pty > 0)
		{
			_pointX = ptx;
		}
		if (ptx > 0)
		{
			_pointY = pty;
		}
	}
	
	private function _loadSub(node:Xml,iteration:Int=0):Void
	{
		var loadsubi:Int = 0;
		var error:String = " ";
		var type:String = node.nodeName;
		type.toLowerCase();
		var obj:Fast = new Fast(node);
		
		//if a "load_if" tag is wrapped around a block of other tags
		//then do the load test, and if so, load all the children inside the block
		if (type == "load_if")
		{
			if (_loadTest(obj))
			{
				if (node.firstElement() != null)
				{
					for (subNode in node.elements())
					{
						_loadSub(subNode,iteration+1);
					}
				}
			}
			
			return;	//exit early
		}
		
		var group_name:String="";
		var tempGroup:FlxUIGroup = null;
		
		var thing_name:String = U.xml_name(obj.x);
		//If it belongs to a group, get that information ready:
		if (obj.has.group) { 
			group_name = obj.att.group; 
			tempGroup = getGroup(group_name);
		}
		//Make the thing
		
		var thing = _loadThing(type, obj);
		
		if (thing != null) {
			_loadGlobals(obj, thing);
			
			var info = _loadThingGetInfo(obj);
			if (info != null)
			{
				obj = info;
			}
			
			if (thing_name != null && thing_name != "") {
				_asset_index.set(thing_name, thing);
				
				//The widget name can be used in getEvent-handlers.
				thing.name = thing_name;
				
				var thing_tags:String = U.xml_str(obj.x, "tags");
				if (thing_tags != "")
				{
					var tagArr:Array<String> = thing_tags.split(",");
					_addTags(tagArr, thing_name);
				}
			}
			
			if (Std.is(thing, IFlxUIButton) || Std.is(thing, IFlxUIClickable))
			{
				_loadTooltip(thing, obj);
			}
			
			if (tempGroup != null) {
				tempGroup.add(cast thing);
			}else {
				//add(cast thing);
				addThing(cast thing);
			}
		
			_loadPosition(obj, thing);	//Position the thing if possible
		}
	}
	
	@:access(flixel.text.FlxText)
	private function addThing(thing:FlxSprite)
	{
		if (Std.is(thing, FlxUIText))
		{
			var ftu:FlxUIText = cast thing;
			var oldRegen = ftu._regen;
			ftu._regen = false;
			add(thing);
			ftu._regen = oldRegen;
		}
		else
		{
			add(thing);
		}
	}
	
	private function _addTags(arr:Array<String>, thingName:String):Void
	{
		for (tag in arr)
		{
			var list:Array<String> = null;
			if (!_tag_index.exists(tag))
			{
				_tag_index.set(tag, []);
			}
			list = _tag_index.get(tag);
			if (list.indexOf(thingName) == -1)
			{
				list.push(thingName);
			}
		}
	}

	private function _loadGlobals(data:Fast, thing:Dynamic)
	{
		if(Std.is(thing, FlxBasic))
		{
			var isVis:Bool = U.xml_bool(data.x, "visible", true);
			var isActive:Bool = U.xml_bool(data.x, "active", true);
			var numID:Int = U.xml_i(data.x, "num_id");
			
			thing.visible = isVis;
			thing.active = isActive;
			thing.ID = numID;
			if (Std.is(thing, FlxSprite))
			{
				var alpha:Float = U.xml_f(data.x, "alpha", 1.0);
				var s:FlxSprite = cast thing;
				s.alpha = alpha;
			}
		}
	}
	
	private function _postLoad(data:Fast):Void
	{
		_postLoaded = true;
		if (data.x.firstElement() != null) {
			//Load the actual things
			var node:Xml;
			for (node in data.x.elements()) 
			{
				_postLoadThing(node.nodeName.toLowerCase(), new Fast(node));
			}
		}
		
		if (data.hasNode.mode) {
			for (mode_node in data.nodes.mode) {
				var is_default:Bool = U.xml_bool(mode_node.x, "is_default");
				if (is_default) {
					var mode_name:String = U.xml_name(mode_node.x);
					setMode(mode_name);
					break;
				}
			}
		}
			
		if (_failure_checks != null) {
			for (data in _failure_checks) {
				if (_checkFailure(data)) {
					failed = true;
					break;
				}
			}
			U.clearArraySoft(_failure_checks);
			_failure_checks = null;
		}
		
		_onFinishLoad();
	}
	
	private function _sendTo(thing:IFlxUIWidget, dir:Int):Void
	{
		var group:FlxUIGroup = getAssetGroup(thing);
		if (group == null)
		{
			if (members.indexOf(cast thing) != -1)
			{
				group = this;
			}
			else
			{
				return;
			}
		}
		if (dir != -1 && dir != 1)
		{
			return;
		}
		
		group.members.remove(cast thing);
		
		switch(dir)
		{
			case -1: group.members.insert(0, cast thing);
			case  1: group.members.push(cast thing);
		}
	}
	
	/**
	 * Send an asset to the front of the member list that it's in
	 * @param	name string identifier of the asset
	 * @param	recursive whether to check superIndex if not found
	 */
	
	public function sendToFront(name:String, recursive:Bool = true):Void
	{
		var thing = getAsset(name, recursive);
		if (thing != null) _sendTo(thing, 1);
	}
	
	/**
	 * Send an asset to either the back of the member list that it's in
	 * @param	name string identifier of the asset
	 * @param	recursive whether to check superIndex if not found
	 */
	
	public function sendToBack(name:String, recursive:Bool = true):Void
	{
		var thing = getAsset(name, recursive);
		if (thing != null) _sendTo(thing, -1);
	}
	
	public var currMode(get, set):String;
	private function get_currMode():String { return _curr_mode; }
	private function set_currMode(m:String):String { setMode(m); return _curr_mode;}
	
	/**
	 * Set a mode for this UI. This lets you show/hide stuff basically. 
	 * @param	mode_name The mode you want, say, "empty" or "play" for a save slot
	 * @param	target_name UI element to target - "" for the UI itself, otherwise the name of an element that is itself a FlxUI
	 */
	
	public function setMode(mode_name:String, target_name:String = ""):Void
	{
		if (_curr_mode == mode_name)
		{
			return;					//no sense in setting the same mode twice!
		}
		var mode:Fast = getMode(mode_name);
		_curr_mode = mode_name;
		var name:String = "";
		var thing;
		if(target_name == ""){
			if (mode != null) {
				
				var xml:Xml;
				for (node in mode.elements) {
					
					var node2:Fast = applyNodeConditionals(node);	//check for conditionals
					xml = node2.x;
					
					var nodeName:String = xml.nodeName;
					
					//check if we're also setting active status
					var activeStatus:Null<Bool> = U.xml_str(xml, "active") == "" ? null : true;
					if (activeStatus != null)
					{
						activeStatus = U.xml_bool(xml, "active");
					}
					
					if (_loadTest(node2))
					{
						switch(nodeName) {
							case "show":
								showThing(U.xml_name(xml), true, activeStatus);
							case "hide":
								showThing(U.xml_name(xml), false, activeStatus);
							case "align":
								_alignThing(node2);
							case "change":
								_changeThing(node2);
							case "position":
								name = U.xml_name(xml);
								thing = getAsset(name);
								if(thing != null){
									_loadPosition(node2, thing);
								}
						}
					}
				}
			}
		}else {
			var target = getAsset(target_name);
			if (target != null && Std.is(target, FlxUI)) {
				var targetUI:FlxUI = cast(target, FlxUI);
				targetUI.setMode(mode_name, "");
			}
		}
	}
	
	private function showThing(name:String, visibleStatus:Bool = true, activeStatus:Null<Bool> = null):Void
	{
		if (name.indexOf(",") != -1)
		{
			var names:Array<String> = name.split(",");			//if commas, it's a list
			for (each_name in names)
			{
				var thing = getAsset(each_name);
				if (thing != null)
				{
					thing.visible = visibleStatus;
					if (activeStatus != null)
					{
						thing.active = activeStatus;
					}
				}
				else
				{
					var group = getGroup(each_name);
					if (group != null)
					{
						group.visible = visibleStatus;
						if (activeStatus != null)
						{
							group.active = activeStatus;
						}
					}
				}
			}
		}
		else
		{
			if (name != "*")
			{
				var thing = getAsset(name);					//else, it's just one asset
				if (thing != null)
				{
					thing.visible = visibleStatus;
					if (activeStatus != null)
					{
						thing.active = activeStatus;
					}
				}
				else
				{
					var group = getGroup(name);
					if (group != null)
					{
						group.visible = visibleStatus;
						if (activeStatus != null)
						{
							group.active = activeStatus;
						}
					}
				}
			}
			else											//if it's a "*", do this for ALL assets
			{
				for (asset_name in _asset_index.keys())
				{
					if (asset_name != "*")					//assets can't be named "*", smartass!
					{
						showThing(asset_name, visibleStatus, activeStatus);	//recurse
					}
				}
			}
		}
	}
	
	/******UTILITY FUNCTIONS**********/
	
	public function getGroup(key:String, recursive:Bool = true):FlxUIGroup
	{
		var tempGroup:FlxUIGroup = _group_index.get(key);
		if (tempGroup == null && recursive && _superIndexUI != null)
		{
			return _superIndexUI.getGroup(key, recursive);
		}
		return tempGroup;
	}
	
	public function getFlxText(key:String, recursive:Bool = true):FlxText
	{
		var asset = getAsset(key, recursive);
		if (asset != null)
		{
			if (Std.is(asset, FlxText))
			{
				return cast(asset, FlxText);
			}
		}
		return null;
	}
	
	public function getAllAssets():Array<IFlxUIWidget>
	{
		var arr:Array<IFlxUIWidget> = [];
		for (key in _asset_index.keys())
		{
			arr.push(getAsset(key));
		}
		return arr;
	}
	
	public function getAssetKeys():Array<String>
	{
		var arr:Array<String> = [];
		for (key in _asset_index.keys()) {
			arr.push(key);
		}
		return arr;
	}
	
	public function hasAsset(key:String, recursive:Bool = true):Bool
	{
		if (_asset_index.exists(key))
		{
			return true;
		}
		if (recursive && _superIndexUI != null)
		{
			return _superIndexUI.hasAsset(key, recursive);
		}
		return false;
	}
	
	public function getAsset(key:String, recursive:Bool = true):IFlxUIWidget
	{
		var asset:IFlxUIWidget = _asset_index.get(key);
		if (asset == null && recursive && _superIndexUI != null)
		{
			return _superIndexUI.getAsset(key, recursive);
		}
		return asset;
	}
	
	public function getAssetsWithTag(tag:String):Array<IFlxUIWidget>
	{
		if (_tag_index.exists(tag))
		{
			var list = _tag_index.get(tag);
			if (list == null || list.length == 0) return null;
			var arr = [];
			for (key in list)
			{
				var widget = getAsset(key);
				if (widget != null)
				{
					arr.push(widget);
				}
			}
			return arr;
		}
		return null;
	}
	
	/**
	 * Get the group that contains a given IFlxUIWidget
	 * @param	key	the asset key of the IFlxUIWidget
	 * @param	thing the IFlxUIWidget itself
	 * @return
	 */
	
	public function getAssetGroup(?key:String,?thing:IFlxUIWidget):FlxUIGroup
	{
		if (thing == null && (key == null || key == "")) return null;
		if (thing == null) thing = getAsset(key);
		if (thing == null) return null;
		
		for (key in _group_index.keys())
		{
			var g = _group_index.get(key);
			if (g.members.indexOf(cast thing) != -1)
			{
				return g;
			}
		}
		
		return null;
	}
	
	public function getMode(key:String, recursive:Bool = true):Fast
	{
		var mode:Fast = _mode_index.get(key);
		if (mode == null && recursive && _superIndexUI != null)
		{
			return _superIndexUI.getMode(key, recursive);
		}
		return mode;
	}

	public function getLabelStyleFromDefinition(key:String, recursive:Bool = true):ButtonLabelStyle
	{
		var definition:Fast = getDefinition(key, recursive);
		if (definition != null)
		{
			var fontDef:FontDef = _loadFontDef(definition);
			var align:String = U.xml_str(definition.x, "align"); if (align == "") { align = null;}
			var color:Int = _loadColor(definition);
			var border:BorderDef = _loadBorder(definition);
			return new ButtonLabelStyle(fontDef, align, color, border);
		}
		return null;
	}
	
	public function getLabelStyleFromData(data:Fast):ButtonLabelStyle
	{
		var fontDef:FontDef = _loadFontDef(data);
		var align:String = U.xml_str(data.x, "align"); if (align == "") { align = null; }
		var color:Int = _loadColor(data);
		var border:BorderDef = _loadBorder(data);
		return new ButtonLabelStyle(fontDef, align, color, border);
	}
	
	public function checkVariable(key:String, otherValue:String, type:String, operator:String = "==", recursive:Bool = true):Bool
	{
		var variable:String = getVariable(key, recursive);
		if (variable != null)
		{
			return U.compareStringVars(variable, otherValue, type, operator);
		}
		else 
		{
			return U.compareStringVars("", otherValue, type, operator);
		}
	}
	
	public function setVariable(key:String, value:String):Void
	{
		_variable_index.set(key, value);
	}
	
	public function getVariable(key:String, recursive:Bool = true):String
	{
		var variable:String = _variable_index.get(key);
		if (variable == null && recursive && _superIndexUI != null)
		{
			variable = _superIndexUI.getVariable(key, recursive);
		}
		return variable;
	}
	
	public function getDefinition(key:String, recursive:Bool = true):Fast
	{
		var definition:Fast = _definition_index.get(key);
		if (definition == null && recursive && _superIndexUI != null)
		{
			definition = _superIndexUI.getDefinition(key, recursive);
		}
		if (definition == null)	//still null? check the globals:
		{
			if (key.indexOf("include:") == -1)
			{
				//check if this definition exists with the prefix "include:"
				//but stop short of recursively churning on "include:include:etc"
				definition = getDefinition("include:" + key, recursive);
			}
		}
		
		return definition;
	}
	
	/**
	 * Adds to thing.x and/or thing.y with wrappers depending on type
	 * @param	thing
	 * @param	X
	 * @param	Y
	 */
	
	private static inline function _delta(thing:IFlxUIWidget, X:Float = 0, Y:Float = 0):Void
	{
		thing.x += X;
		thing.y += Y;
	}
		
	/**
	 * Centers thing in x axis with wrappers depending on type
	 * @param	thing
	 * @param	amt
	 */
		
	private static inline function _center(thing:IFlxUIWidget, X:Bool = true, Y:Bool = true):IFlxUIWidget
	{
		if (X) { thing.x = (FlxG.width - thing.width) / 2; }
		if (Y) { thing.y = (FlxG.height - thing.height) / 2;}
		return thing;
	}
	
	private function screenWidth():Int
	{
		if (hasAsset("screen"))
		{
			return Std.int(getAsset("screen").width);
		}
		return FlxG.width;
	}
	
	private function screenHeight():Float
	{
		if (hasAsset("height"))
		{
			return Std.int(getAsset("screen").height);
		}
		return FlxG.height;
	}
	
	/***PRIVATE***/
	
	@:allow(FlxUI)
	private var _postLoaded:Bool = false;
	
	private var _pointX:Float = 1;
	private var _pointY:Float = 1;
	
	private var _group_index:Map<String,FlxUIGroup>;
	private var _asset_index:Map<String,IFlxUIWidget>;
	private var _tag_index:Map<String,Array<String>>;
	private var _definition_index:Map<String,Fast>;
	private var _variable_index:Map<String,String>;
	private var _mode_index:Map<String,Fast>;
	
	private var _curr_mode:String = "";
	
	private var _ptr:IEventGetter;

	private var _superIndexUI:FlxUI;
	private var _safe_input_delay_elapsed:Float = 0.0;
	
	private var _failure_checks:Array<Fast>;
	
	private var _assetsToCleanUp:Array<String>=[]; //assets to remove from the cache after the state is initialized
	private var _scaledAssets:Array<String> = [];
	
	/**
	 * Replace an object in whatever group it is in
	 * @param	original the original object
	 * @param	replace	the replacement object
	 * @param	splice if replace is null, whether to splice the entry
	 */
	 
	private function replaceInGroup(original:FlxSprite,replace:FlxSprite,splice:Bool=false){
		//Slow, unoptimized, searches through everything
		
		if(_group_index != null){
			for (key in _group_index.keys()) {
				var tempGroup:FlxUIGroup = _group_index.get(key);
				if (tempGroup.members != null) {
					var i:Int = 0;
					for (member in tempGroup.members) {
						if(member != null){
							if (member == original) {
								tempGroup.members[i] = replace;
								if (replace == null) {
									if (splice) {
										tempGroup.members.splice(i, 1);
										i--;
									}
								}
								return;
							}
							i++;
						}
					}
				}
			}
		}
		
		//if we get here, it's not in any group, it's just in our global member list
		if (this.members != null) {
			var i:Int = 0;
			for (member in this.members) {
				if(member != null){
					if (member == original) {
						members[i] = replace;
						if (replace == null) {
							if (splice) {
								members.splice(i, 1);
								i--;
							}
						}
						return;
					}
				}
				i++;
			}
		}
	}
	
	/************LOADING FUNCTIONS**************/
	
	private function applyNodeConditionals(info:Fast):Fast{
		if (info.hasNode.locale || info.hasNode.haxedef || info.hasNode.window || info.hasNode.change_if) {
			info = U.copyFast(info);
			
			if(info.hasNode.locale){
				info = applyNodeChanges(info, "locale");
			}
			
			if (info.hasNode.haxedef) {
				info = applyNodeChanges(info, "haxedef");
			}
			
			if (info.hasNode.window) {
				info = applyNodeChanges(info, "window");
			}
			
			if (info.hasNode.change_if)
			{
				if (_loadTest(info.node.change_if, "change_if"))
				{
					info = applyNodeChanges(info, "change_if");
				}
			}
		}
		return info;
	}
	
	/**
	 * Make any necessary changes to data/definition xml objects (such as for locale or haxedef settings)
	 * @param	data		Fast xml data
	 * @param	nodeName	name of the node, "locale", "haxedef", or "resolution"
	 */
	
	private function applyNodeChanges(data:Fast,nodeName:String):Fast {
		//Make any necessary UI adjustments based on locale
		
		var nodeValue:String = "";
		
		//If nodeName="locale", set nodeValue once and only match current locale
		if (nodeName == "locale") {
			if (_ptr_tongue == null) {
				return data;
			}
			nodeValue = _ptr_tongue.locale.toLowerCase();	//match current locale only
		}
		
		//Else if nodeName="haxedef", check each valid haxedef inside the loop itself
		var haxedef:Bool = false;
		if (nodeName == "haxedef") {
			haxedef = true;
		}
		
		//Else if nodeName="window", check to see if we match this resolution
		if (nodeName == "window") {
			nodeValue = FlxG.width + "," + FlxG.height;
		}
		
		var freePass = false;
		if (nodeName == "change_if")
		{
			freePass = true;
		}
		
		for (cNode in data.nodes.resolve(nodeName)) {
			var cname:String = U.xml_name(cNode.x);
			var cnames:Array<String> = cname.indexOf(",") != -1 ? cname.split(",") : [];
			
			if(haxedef){
				nodeValue = "";
				if (U.checkHaxedef(cname)) {
					nodeValue = cname;
				}
			}
			
			if (freePass || cname == nodeValue || cnames.indexOf(nodeValue) != -1) {
				if (cNode.hasNode.change) {
					for (change in cNode.nodes.change) {
						for (att in change.x.attributes()) {
							var value:String = change.x.get(att);
							data.x.set(att, value);
						}
					}
				}
				if (cNode.hasNode.change_node)
				{
					for (changeNode in cNode.nodes.change_node)
					{
						var nodeToChange = U.xml_name(changeNode.x);
						if (data.hasNode.resolve(nodeToChange))
						{
							var dataNode = data.node.resolve(nodeToChange);
							for (att in changeNode.x.attributes())
							{
								var value:String = changeNode.x.get(att);
								dataNode.x.set(att, value);
							}
						}
					}
				}
			}
		}
		
		return data;
	}

	/**
	 * Load an individual flixel-ui widget from a snippet of xml
	 * @param	type
	 * @param	data
	 * @return
	 */
	
	public function loadThing(type:String, data:Fast):IFlxUIWidget
	{
		return _loadThing(type, data);
	}
	
	private function _loadThingGetInfo(data:Fast):Fast
	{
		var nodeName:String = data.x.nodeName;
		var defaultDef = getDefinition("default:" + nodeName);
		
		//TODO: since it looks for the default definition based on the specific node-name, there could be bugs if you mix & match synonymous tags like <9slicesprite> and <chrome>,
		//but only specify a default for one of them. I might need to add some robustness checking later.
		
		var info:Fast = null;
		if (defaultDef != null)
		{
			info = consolidateData(data, defaultDef, true);
		}
		
		if (info == null)
		{
			info = data;
		}
		
		var definition:Fast = getUseDef(info);
		info = consolidateData(info, definition);
		info = applyNodeConditionals(info);
		
		if (_loadTest(info) == false)
		{
			return null;
		}
		
		return info;
	}
	
	private function _loadTooltip(thing:IFlxUIWidget, data:Fast):Void
	{
		if (data.hasNode.tooltip)
		{
			var tt    = _loadTooltipData(data.node.tooltip);
			var state = getLeafUIState();
			
			if (Std.is(thing, IFlxUIButton))
			{
				state.tooltips.add(cast thing, tt);
			}
			else if (Std.is(thing, FlxUICheckBox))
			{
				var check:FlxUICheckBox = cast thing;
				state.tooltips.add(check.button, tt);
			}
		}
	}
	
	private function _loadTooltipData(tNode:Fast):FlxUITooltipData
	{
		var tt = {
			title:"", 
			body:"", 
			anchor:null, 
			style: {
				titleFormat:null,
				bodyFormat:null,
				titleBorder:null,
				bodyBorder:null,
				titleOffset:null,
				bodyOffset:null,
				titleWidth: -1,
				bodyWidth: -1,
				
				background:null,
				borderSize:-1,
				borderColor:null,
				arrow:null,
				
				autoSizeVertical:null,
				autoSizeHorizontal:null,
				
				leftPadding: -1,
				rightPadding: -1,
				topPadding: -1,
				bottomPadding: -1
			}
		};
		
		var defaultDef = getDefinition("default:tooltip");
		if (defaultDef != null)
		{
			tNode = consolidateData(tNode, defaultDef, true);
		}
		
		if (tNode.has.use_def)
		{
			var def = getUseDef(tNode);
			tNode = consolidateData(tNode, def, true);
		}
		
		if (tNode.has.text)
		{
			_loadTooltipText(tNode, "text", tt);
		}
		
		if (tNode.hasNode.title)
		{
			_loadTooltipText(tNode.node.title, "text", tt);
		}
		if (tNode.hasNode.body)
		{
			_loadTooltipText(tNode.node.body, "text", tt);
		}
		
		tt.anchor = _loadAnchor(tNode);
		
		_loadTooltipStyle(tNode, tt);
		
		return tt;
	}
	
	private function _loadTooltipStyle(node:Fast, tt:FlxUITooltipData):Void
	{
		tt.style.background  = U.xml_color(node.x, "background");
		tt.style.borderSize  = U.xml_i(node.x, "border", -1);
		tt.style.borderColor = U.xml_color(node.x, "border_color");
		
		tt.style.arrow = node.has.arrow ? U.xml_gfx(node.x, "arrow") : null;
		
		tt.style.autoSizeHorizontal = U.xml_bool(node.x, "auto_size_horizontal", true);
		tt.style.autoSizeVertical   = U.xml_bool(node.x, "auto_size_vertical", true);
		
		var padAll = Std.int(_loadHeight(node, -1, "pad_all"));
		if (padAll != -1)
		{
			tt.style.leftPadding = tt.style.rightPadding = tt.style.topPadding = tt.style.bottomPadding = padAll;
		}
		else
		{
			tt.style.leftPadding   = Std.int(_loadWidth(node, 0, "pad_left"));
			tt.style.rightPadding  = Std.int(_loadWidth(node, 0, "pad_right"));
			tt.style.topPadding    = Std.int(_loadHeight(node, 0, "pad_top"));
			tt.style.bottomPadding = Std.int(_loadHeight(node, 0, "pad_bottom"));
		}
	}
	
	private function _loadTooltipText(node:Fast, fieldName:String, tt:FlxUITooltipData):Void
	{
		var nodeName = node.name;
		var text     = _loadString(node, fieldName);
		
		var offset = new FlxPoint(_loadX(node), _loadY(node));
		
		if (node.has.use_def)
		{
			var the_def = getUseDef(node);
			node = consolidateData(node, the_def);
		}
		
		var border = _loadBorder(node);
		var format = _loadFontDef(node);
		var color:Null<FlxColor> = U.xml_color(node.x, "color", true, FlxColor.BLACK);
		format.format.color = color;
		
		var W = Std.int(_loadWidth(node, -1, "width"));
		
		switch(nodeName)
		{
			case "tooltip", "title": 
				if (text != "")
				{
					tt.title = text;
				}
				tt.style.titleOffset = offset;
				tt.style.titleFormat = format;
				tt.style.titleWidth = W;
				tt.style.titleBorder = border;
			case "body":
				if (text != "")
				{
					tt.body = text;
				}
				tt.style.bodyOffset = offset;
				tt.style.bodyFormat = format;
				tt.style.bodyWidth = W;
				tt.style.bodyBorder = border;
			default:
				//do nothing
		}
	}
	
	private function _loadAnchor(data:Fast):Anchor
	{
		var xOff = _loadX(data);
		var yOff = _loadY(data);
		if (data.hasNode.anchor)
		{
			var xSide = U.xml_str(data.node.anchor.x, "x", true, "right");
			var ySide = U.xml_str(data.node.anchor.x, "y", true, "top");
			var xFlush = U.xml_str(data.node.anchor.x, "x-flush", true, "left");
			var yFlush = U.xml_str(data.node.anchor.x, "y-flush", true, "top");
			return new Anchor(xOff, yOff, xSide, ySide, xFlush, yFlush);
		}
		return null;
	}
	
	private function _loadThing(type:String, data:Fast):IFlxUIWidget{
		
		var info = _loadThingGetInfo(data);
		if (info == null)
		{
			return null;
		}
		
		var returnThing:IFlxUIWidget = null;
		
		switch(type) {
			case "region": returnThing =  _loadRegion(info);
			case "chrome", "nineslicesprite", "nine_slice_sprite", "nineslice", "nine_slice": returnThing = _load9SliceSprite(info);
			case "tile_test": returnThing =  _loadTileTest(info);
			case "line": returnThing =  _loadLine(info);
			case "box": returnThing =  _loadBox(info);
			case "sprite": returnThing =  _loadSprite(info);
			case "bar": returnThing =  _loadBar(info);
			case "text": returnThing =  _loadText(info, false);								//if input has events
			case "text_region": returnThing = _loadText(info, true);
			case "input_text": returnThing =  _loadInputText(info);								//if input has events
			case "numstepper","num_stepper","numeric_stepper": returnThing =  _loadNumericStepper(info);			//has events, params
			case "button": returnThing =  _loadButton(info);							//has events, params
			case "button_toggle": returnThing =  _loadButton(info,true,true);			//has events, params
			
			case "tab_menu": returnThing =  _loadTabMenu(info);							//has events, params?
			
			case "dropdown_menu", "dropdown",
			     "pulldown", "pulldown_menu": returnThing =  _loadDropDownMenu(info);	//has events, params?
			
			case "checkbox": returnThing =  _loadCheckBox(info);						//has events, params
			case "radio_group": returnThing =  _loadRadioGroup(info);					//has events, params
			case "layout", "ui": returnThing =  _loadLayout(info);
			case "failure": if (_failure_checks == null) { _failure_checks = new Array<Fast>(); }
							unparentXML(info);
							_failure_checks.push(info);
							returnThing =  null;
			case "align": 	_alignThing(info,true);				//we suppress errors first time through b/c they only matter if still present at postLoad()
							returnThing =  null;
			case "mode", "include", "inject", "default", "group", "load_if":	//ignore these, they are handled elsewhere
							returnThing =  null;
			case "change":
							_changeThing(info);
							returnThing =  null;
			case "position":
							name = U.xml_name(info.x);
							var thing = getAsset(name);
							if(thing != null){
								_loadPosition(info, thing);
							}
							returnThing =  null;
			case "show","hide":
						var activeStatus:Null<Bool> = U.xml_str(info.x, "active") == "" ? null : true;
						if (activeStatus != null) activeStatus = U.xml_bool(info.x, "active");
						var showHide = (type == "show" ? true : false);
						showThing(U.xml_name(info.x), showHide, activeStatus);
			
			default: 
				//If I don't know how to load this thing, I will request it from my pointer:
				var result = _ptr.getRequest("ui_get:" + type, this, info, [data]);
				returnThing =  result;
		}
		
		if (!moves && returnThing != null)
		{
			returnThing.moves = false;
		}
		
		return returnThing;
	}
	
	//Handy helpers for making x/y/w/h loading dynamic:
	private inline function _loadX(data:Fast, default_:Float = 0):Float
	{
		return _loadWidth(data, default_, "x");
	}
	
	private inline function _loadY(data:Fast, default_:Float = 0):Float
	{
		return _loadHeight(data, default_, "y");
	}
	
	private function _loadScale(data:Fast, default_:Float = 1.0, str:String="scale"):Float
	{
		return _loadHeight(data, default_, str, "none");
	}
	
	private function _loadScaleX(data:Fast, default_:Float = 1.0):Float
	{
		return _loadWidth(data, default_, "scale_x", "none");
	}
	
	private function _loadScaleY(data:Fast, default_:Float = 1.0):Float
	{
		return _loadHeight(data, default_, "scale_y", "none");
	}
	
	private function _loadWidth(data:Fast, default_:Float = 10, str:String = "width", defaultRound:String = ""):Float
	{
		var ws:String = U.xml_str(data.x, str, true, Std.string(default_));
		var round:Rounding = getRound(data, defaultRound);
		return doRound(_getDataSize("w", ws, default_), round);
	}
	
	private function _loadHeight(data:Fast, default_:Float = 10, str:String = "height", defaultRound:String = ""):Float
	{
		var hs:String = U.xml_str(data.x, str, true, Std.string(default_));
		var round:Rounding = getRound(data, defaultRound);
		return doRound(_getDataSize("h", hs, default_), round);
	}
	
	private function _loadCompass(data:Fast, str:String = "resize_point"):FlxPoint
	{
		var cs:String = U.xml_str(data.x, str, true, "nw");
		var fp:FlxPoint = FlxPoint.get();
		switch(cs) {
			case "nw", "ul": fp.x = 0;   fp.y = 0;
			case "n", "u":   fp.x = 0.5; fp.y = 0;
			case "ne", "ur": fp.x = 1;   fp.y = 0;
			case "e", "r":   fp.x = 1;   fp.y = 0.5;
			case "se", "lr": fp.x = 1;   fp.y = 1;
			case "s":        fp.x = 0.5; fp.y = 1;
			case "sw", "ll": fp.x = 0;   fp.y = 1;
			case "w":        fp.x = 0.5; fp.y = 0;
			case "m","c","mid","center":fp.x = 0.5; fp.y = 0.5;
		}
		return fp;
	}
	
	private function _changeParamsThing(data:Fast):Void
	{
		var name:String = U.xml_name(data.x);
		var thing:IFlxUIWidget = getAsset(name);
		if (thing == null) {
			return;
		}
		
		if (!Std.is(thing, IHasParams)) {
			return;
		}
		
		var i:Int = 0;
		if (Std.is(thing, IHasParams)) {
			
		}
		var ihp:IHasParams = cast thing;
		ihp.params = getParams(data);
	}
	
	private function _changeThing(data:Fast):Void
	{
		var name:String = U.xml_name(data.x);
		var thing = getAsset(name);
		if (thing == null)
		{
			return;
		}
		
		var new_width:Float = -1;
		var new_height:Float = -1;
		
		var context:String = "";
		var code:String = "";
		
		var labelStyleChanged:Bool = false;
		
		for (attribute in data.x.attributes())
		{
			switch(attribute)
			{
				case "src": if (Std.is(thing, FlxUISprite))
							{
								var src = loadScaledSrc(data);
								var spr:FlxUISprite = cast thing;
								spr.loadGraphic(src);
							}
				case "text": if (Std.is(thing, FlxUIText))
							 {
								var text = U.xml_str(data.x, "text");
								context = U.xml_str(data.x, "context", true, "ui");
								var t:FlxUIText = cast thing;
								code = U.xml_str(data.x, "code", true, "");
								t.text = getText(text, context, true, code);
							 }
				case "label": var label = U.xml_str(data.x, "label");
							  context = U.xml_str(data.x, "context", true, "ui");
							  code = U.xml_str(data.x, "code", true, "");
							  label = getText(label, context, true, code);
							  
							  if (Std.is(thing, ILabeled))
							  {
								  var b:ILabeled = cast thing;
								  b.getLabel().text = label;
							  }
							  else if (Std.is(thing, FlxUISpriteButton))
							  {
								  U.setButtonLabel(cast thing, label);
							  }
				case "width": new_width = _loadWidth(data);
				case "height": new_height = _loadHeight(data);
			}
		}
		if (Std.is(thing, IResizable))
		{
			var ir:IResizable = cast thing;
			if (new_width != -1 || new_height != -1)
			{
				if (new_width == -1) { new_width = ir.width; }
				if (new_height == -1) { new_height = ir.height; }
				ir.resize(new_width, new_height);
			}
		}
		
		if (data.hasNode.param)
		{
			if (Std.is(thing, IHasParams))
			{
				var ihp:IHasParams = cast thing;
				ihp.params = getParams(data);
			}
		}
	}
	
	
	
	private function _alignThing(data:Fast,suppressError:Bool=false):Void
	{
		var datastr:String = data.x.toString();
		if (data.hasNode.objects)
		{
			for (objectNode in data.nodes.objects)
			{
				var objects:Array<String> = U.xml_str(objectNode.x, "value", true, "").split(",");
				
				var objStr = U.xml_str(objectNode.x, "value", true, "");
				var objects = objStr.split(",");
				var axis:String = U.xml_str(data.x, "axis", true);
				if (axis != "horizontal" && axis != "vertical")
				{
					throw new Error("FlxUI._alignThing(): axis must be \"horizontal\" or \"vertical\"!");
					return;
				}
				
				var spacing:Float = -1;
				if (axis == "horizontal")
				{
					spacing = _getDataSize("w", U.xml_str(data.x,"spacing",true), -1);
				}
				else
				{
					spacing = _getDataSize("h", U.xml_str(data.x,"spacing",true), -1);
				}
				
				var resize:Bool = U.xml_bool(data.x, "resize");
				
				var grow:Bool = U.xml_bool(data.x, "grow", true);
				var shrink:Bool = U.xml_bool(data.x, "shrink", true);
				
				var bounds:FlxPoint = FlxPoint.get(-1,-1);
				
				var boundsError:String = "";
				
				if (data.hasNode.bounds)
				{
					var bound_range:Float = -1;
					
					if (axis == "horizontal") {
						bounds.x = _getDataSize("w", U.xml_str(data.node.bounds.x, "left"), -1);
						bounds.y = _getDataSize("w", U.xml_str(data.node.bounds.x, "right"), -1);
					}else if (axis == "vertical") {
						bounds.x = _getDataSize("h", U.xml_str(data.node.bounds.x, "top"), -1);
						bounds.y = _getDataSize("h", U.xml_str(data.node.bounds.x, "bottom"), -1);
					}
				}
				
				if (bounds.x != -1 && bounds.y != -1)
				{
					if (bounds.y <= bounds.x)
					{
						boundsError = "bounds max must be > bounds min! (max=" + bounds.y + " min=" + bounds.x + ")";
					}
				}
				else
				{
					boundsError = "missing bound!";
				}
				
				if (boundsError == "")
				{
					_doAlign(objects, axis, spacing, resize, bounds, grow, shrink);
				}
				
				if (data.hasNode.anchor || data.has.x || data.has.y)
				{
					for (object in objects)
					{
						var thing:IFlxUIWidget = getAsset(object);
						_loadPosition(data,thing);
					}
				}
				else
				{
					if (boundsError != "")
					{
						if (!suppressError)
						{
							FlxG.log.error(boundsError);
						}
					}
				}
			}
		}
		else
		{
			throw new Error("FlxUI._alignThing(): <objects> node not found!");
			return;
		}
	}
	
	private function _doAlign(objects:Array<String>, axis:String, spacing:Float, resize:Bool, bounds:FlxPoint, allowGrow:Bool = true, allowShrink:Bool = true):Void
	{
		var total_spacing:Float = 0;
		var total_size:Float = 0;
		
		var bound_range:Float = bounds.y - bounds.x;
		
		var spaces:Float = objects.length-1;
		var space_size:Float = 0;
		var object_size:Float = 0;
		
		var size_prop:String = "width";
		var pos_prop:String = "x";
		if (axis == "vertical")
		{ 
			size_prop = "height"; 
			pos_prop = "y"; 
		}
		
		//calculate total size of everything
		for (nameStr in objects)
		{
			var widget:IFlxUIWidget = getAsset(nameStr);
			if (widget != null)
			{
				
				var theval:Float = 0;
				switch(size_prop)
				{
					case "width": theval = widget.width;
					case "height": theval = widget.height;
				}
				
				total_size += theval;
			}
		}
		
		if (resize == false)	//not resizing, so space evenly
		{
			total_spacing = bound_range - total_size;
			space_size = total_spacing / spaces;
		}
		else					//resizing, calculate space and then get remaining size
		{
			space_size = spacing;
			total_spacing = spacing * spaces;
			object_size = (bound_range - total_spacing) / objects.length;	//target object size
		}
		
		object_size = Std.int(object_size);
		space_size = Std.int(space_size);
		
		var last_pos:Float = bounds.x;
		for (nameStr in objects)
		{
			var widget:IFlxUIWidget = getAsset(nameStr);
			if(widget != null) {
				var pos:Float = last_pos;
				if (!resize)
				{
					switch(size_prop)
					{
						case "width": object_size = widget.width;
						case "height": object_size = widget.height;
					}
				}
				else
				{
					//if we are resizing, resize it to the target size now
					if (Std.is(widget, IResizable))
					{
						var allow:Bool = true;
						var widgetr:IResizable = cast widget;
						if (axis == "vertical")
						{
							if (object_size > widgetr.width)
							{
								allow = allowGrow;
							}
							else if (object_size < widgetr.width)
							{
								allow = allowShrink;
							}
							if (allow && (widgetr.height != object_size))
							{
								widgetr.resize(widgetr.width, object_size);
							}
						}
						else if (axis == "horizontal")
						{
							if (object_size > widgetr.height)
							{
								allow = allowGrow;
							}
							else if (object_size < widgetr.height)
							{
								allow = allowShrink;
							}
							if (allow && (widgetr.width != object_size))
							{
								widgetr.resize(object_size, widgetr.height);
							}
						}
					}
				}
			
				last_pos = pos + object_size + space_size;
				
				switch(pos_prop)
				{
					case "x": widget.x = pos;
					case "y": widget.y = pos;
				}
			}
		}
	}
	
	private function _checkFailure(data:Fast):Bool{
		var target:String = U.xml_str(data.x, "target", true);
		var property:String = U.xml_str(data.x, "property", true);
		var compare:String = U.xml_str(data.x, "compare", true);
		var value:String = U.xml_str(data.x, "value", true);
		
		var thing:IFlxUIWidget = getAsset(target);
		
		if (thing == null) {
			return false;
		}
				
		var prop_f:Float = 0;
		var val_f:Float = 0;
				
		var p:Float = U.perc_to_float(value);
		
		switch(property) {
			case "w", "width": prop_f = thing.width; 
			case "h", "height": prop_f = thing.height; 
		}
				
		if (Math.isNaN(p)) {
			if (U.isStrNum(value)) {
				val_f = Std.parseFloat(value);
			}else {
				return false;
			}
		}else {
			switch(property) {
				case "w", "width": val_f = p * screenWidth(); 
				case "h", "height": val_f = p * screenHeight();
			}
		}
				
		var return_val:Bool = false;
		
		switch(compare) {
			case "<": if (prop_f < val_f) {
						failed_by = val_f - prop_f;
						return_val = true;
					  }
			case ">": if (prop_f > val_f) {
						failed_by = prop_f - val_f;
						return_val = true;
					  }
			case "=", "==": if (prop_f == val_f) {
						failed_by = Math.abs(prop_f - val_f);
						return_val = true;
					  }
			case "<=": if (prop_f <= val_f) {
						failed_by = val_f - prop_f;
						return_val = true;
					  }
			case ">=": if (prop_f >= val_f) {
						failed_by = prop_f - val_f;
						return_val = true;
					  }
		}
	
		return return_val;
	}
	
	private function _resizeThing(fo_r:IResizable, bounds:{ min_width:Float, min_height:Float,
														 max_width:Float, max_height:Float}):Void {
															 
		var do_resize:Bool = false;
		var ww:Float = fo_r.width;
		var hh:Float = fo_r.height;
		
		if (ww < bounds.min_width) {
			do_resize = true; 
			ww = bounds.min_width;
		}else if (ww > bounds.max_width) {
			do_resize = true;
			ww = bounds.max_width;
		}
		
		if (hh < bounds.min_height) {
			do_resize = true;
			hh = bounds.min_height;
		}else if (hh > bounds.max_height) {
			do_resize = true;
			hh = bounds.max_height;
		}
		
		if (do_resize) {
			fo_r.resize(ww,hh);
		}
	}
	
	private function _postLoadThing(type:String, data:Fast):Void
	{
		if (type == "load_if")		//if the whole thing is a load_if tag, evaluate & load all sub elements
		{
			if (_loadTest(data))
			{
				if (data.x.firstElement() != null)
				{
					for (subNode in data.x.elements())
					{
						var nodeType:String = subNode.nodeName.toLowerCase();
						_postLoadThing(nodeType, new Fast(subNode));
					}
				}
			}
			return;
		}
		
		if (_loadTest(data) == false)
		{
			return;
		}
		
		var info = _loadThingGetInfo(data);
		if (info != null)
		{
			data = info;
		}
		
		var name:String = U.xml_name(data.x);
		
		var thing:IFlxUIWidget = getAsset(name);
		var isGroup = type == "group";
		if (isGroup)
		{
			thing = getGroup(name);
		}
		
		if (type == "align") {
			_alignThing(data);
		}
		
		if (type == "change") {
			_changeThing(data);
		}
		
		if (type == "position") {
			_loadPosition(data, thing);
			return;
		}
		
		if (type == "cursor") {
			_loadCursor(data);
		}
		
		if (thing == null && !isGroup) {
			return;
		}
		
		if (!isGroup)
		{
			var use_def:String = U.xml_str(data.x, "use_def", true);
			var definition:Fast = null;
			if (use_def != "") {
				definition = getDefinition(use_def);
			}
			
			if (Std.is(thing, IResizable))
			{
				var ww:Null<Float> = _getDataSize("w", U.xml_str(data.x, "width"));
				var hh:Null<Float> = _getDataSize("h", U.xml_str(data.x, "height"));
				if (ww == 0 || ww == thing.width)
				{
					ww = null;
				}
				if (hh == 0 || hh == thing.height)
				{
					hh = null;
				}
				
				var bounds = calcMaxMinSize(data);
				
				if (bounds != null)
				{
					if (ww != null) {
						if (ww < bounds.min_width) { ww = bounds.min_width; }
						if (ww > bounds.max_width) { ww = bounds.max_width; }
						bounds.min_width = bounds.max_width = ww;
					}
					if (hh != null) {
						if (hh < bounds.min_height){ hh = bounds.min_height;}
						if (hh > bounds.max_height){ hh = bounds.max_height;}
						bounds.min_height = bounds.max_height = hh;
					}
					
					_resizeThing(cast(thing, IResizable), bounds);
				}
			}
			
			_delta(thing, -thing.x, -thing.y);	//reset position to 0,0
			_loadPosition(data, thing);			//reposition
		}
		
		var send_to = U.xml_str(data.x, "send_to", true, "");
		if (send_to != "")
		{
			switch(send_to)
			{
				case "back", "bottom": _sendTo(thing, -1);
				case "front",   "top": _sendTo(thing, 1);
			}
		}
		
		if (!isGroup && Std.is(thing, FlxUI))
		{
			var fui_thing:FlxUI = cast thing;
			if (fui_thing._postLoaded == false)
			{
				fui_thing.getEvent("post_load", this, null);
			}
		}
	}
	
	private function _loadTileTest(data:Fast):FlxUITileTest
	{
		var tiles_w:Int = U.xml_i(data.x, "tiles_w", 2);
		var tiles_h:Int = U.xml_i(data.x, "tiles_h", 2);
		var w:Float = _loadWidth(data);
		var h:Float = _loadHeight(data);
		
		var bounds: { min_width:Float, min_height:Float, 
					  max_width:Float, max_height:Float } = calcMaxMinSize(data);
		
		if (w < bounds.min_width) { w = bounds.min_width; }
		if (h < bounds.min_height) { h = bounds.min_height; }
		
		var tileWidth:Int = Std.int(w/tiles_w);
		var tileHeight:Int = Std.int(h/tiles_h);
		
		if (tileWidth < tileHeight) { tileHeight = tileWidth; }
		else if (tileHeight < tileWidth) { tileWidth = tileHeight; }
		
		var totalw:Float = tileWidth * tiles_w;
		var totalh:Float = tileHeight * tiles_h;
		
		if (totalw > bounds.max_width) { tileWidth = Std.int(bounds.max_width / tiles_w); }
		if (totalh > bounds.max_height) { tileHeight = Std.int(bounds.max_height / tiles_h); }
		
		if (tileWidth < tileHeight) { tileHeight = tileWidth; }
		else if (tileHeight < tileWidth) { tileWidth = tileHeight; }
		
		if (tileWidth < 2) { tileWidth = 2; }
		if (tileHeight < 2) { tileHeight = 2; }
		
		var color1:FlxColor = FlxColor.fromString(U.xml_str(data.x, "color1", true, "0x808080"));
		var color2:FlxColor = FlxColor.fromString(U.xml_str(data.x, "color2", true, "0xc4c4c4"));
		
		var baseTileSize:Int = U.xml_i(data.x, "base_tile_size", -1);
		var floorToEven:Bool = U.xml_bool(data.x, "floor_to_even", false);
		
		var ftt:FlxUITileTest = new FlxUITileTest(0, 0, tileWidth, tileHeight, tiles_w, tiles_h, color1, color2, floorToEven);
		ftt.baseTileSize = baseTileSize;
		return ftt;
	}
	
	private function _loadString(data:Fast, attributeName:String):String
	{
		var string = U.xml_str(data.x, attributeName);
		var context = U.xml_str(data.x, "context", true, "ui");
		var code = U.xml_str(data.x, "code", true, "");
		string = getText(string, context, true, code);
		return string;
	}
	
	@:access(flixel.text.FlxText)
	private function _loadText(data:Fast, asRegion:Bool=false):IFlxUIWidget
	{
		var text:String = U.xml_str(data.x, "text");
		var context:String = U.xml_str(data.x, "context", true, "ui");
		var code:String = U.xml_str(data.x, "code", true, "");
		text = getText(text,context, true, code);
		
		var W:Int = Std.int(_loadWidth(data, 100));
		var H:Int = Std.int(_loadHeight(data, -1));
		
		var the_font:String = _loadFontFace(data);
		
		var input:Bool = U.xml_bool(data.x, "input");
		if(input)
		{
			throw new Error("FlxUI._loadText(): <text> with input has been deprecated. Use <input_text> instead.");
		}
		
		var align:String = U.xml_str(data.x, "align"); if (align == "") { align = null;}
		var size:Int = Std.int(_loadHeight(data, 8, "size", "floor"));
		
		var color:Int = _loadColor(data);
		
		var border:BorderDef = _loadBorder(data);
		
		var backgroundColor:Int = U.parseHex(U.xml_str(data.x, "background", true, "0x00000000"), true, true, 0x00000000);
		
		var leadingExists = U.xml_str(data.x, "leading", true, "");
		var leadingInt = Std.int(_loadHeight(data, 0, "leading", "floor"));
		
		var ft:IFlxUIWidget;
		
		var ftur:FlxUITextRegion = null;
		var ftu:FlxUIText = null;
		var itext:IFlxUIText = null;
		
		if (asRegion)
		{
			ftur = new FlxUITextRegion(0, 0, W, "", size, true);
			ftur.fontDef = FontDef.fromXML(data.x);
			ftur.fontDef.format.leading = leadingExists != "" ? leadingInt : null;
			ftur.text = text;
			ft = ftur;
			itext = cast ftur;
		}
		else
		{
			ftu = new FlxUIText(0, 0, W, "", size, true);
			var dtf = ftu.textField.defaultTextFormat;
			dtf.leading = leadingExists != "" ? leadingInt : null;
			ftu.textField.defaultTextFormat = dtf;
			ftu.setFormat(the_font, size, color, align);
			border.apply(ftu);
			ftu.text = text;
			ftu.drawFrame();
			ft = ftu;
			itext = cast ftu;
		}
		
		if (data.hasNode.param)
		{
			var params = getParams(data);
			var ihp:IHasParams = cast ft;
			ihp.params = params;
		}
		
		if (itext != null)
		{
			if (H > 0 && ft.height != H)
			{
				itext.resize(itext.width, H);
			}
			
			//force text redraw
			itext.text = " ";
			itext.text = text;
		}
		
		return ft;
	}

	private function _loadInputText(data:Fast):IFlxUIWidget
	{
		var text:String = U.xml_str(data.x, "text");
		var context:String = U.xml_str(data.x, "context", true, "ui");
		var code:String = U.xml_str(data.x, "code", true, "");
		text = getText(text,context, true, code);
		
		var W:Int = Std.int(_loadWidth(data, 100));
		var H:Int = Std.int(_loadHeight(data, -1));
		
		var the_font:String = _loadFontFace(data);
		
		var align:String = U.xml_str(data.x, "align"); if (align == "") { align = null;}
		var size:Int = Std.int(_loadHeight(data, 8, "size"));
		var color:Int = _loadColor(data);
		
		var border:BorderDef = _loadBorder(data);
		
		var backgroundColor:Int = U.parseHex(U.xml_str(data.x, "background", true, "0x00000000"), true, true, 0x00000000);
		var passwordMode:Bool = U.xml_bool(data.x, "password_mode");
		
		var ft:IFlxUIWidget;
		var fti:FlxUIInputText = new FlxUIInputText(0, 0, W, text, size, color, backgroundColor);
		fti.passwordMode = passwordMode;
			
		var force_case:String = U.xml_str(data.x, "force_case", true, "");
		var forceCase:Int;
		switch(force_case)
		{
			case "upper", "upper_case", "uppercase": forceCase = FlxInputText.UPPER_CASE;
			case "lower", "lower_case", "lowercase": forceCase = FlxInputText.LOWER_CASE;
			case "u", "l":
					throw new Error("FlxUI._loadInputText(): 1 letter values have been deprecated (force_case attribute).");
			default: forceCase = FlxInputText.ALL_CASES;
		}
		
		var filter:String = U.xml_str(data.x, "filter", true, "");
		var filterMode:Int;
		while (filter.indexOf("_") != -1)
		{
			filter = StringTools.replace(filter, "_", "");	//strip out any underscores
		}
		
		switch(filter)
		{
			case "alpha", "onlyalpha": filterMode = FlxInputText.ONLY_ALPHA;
			case "num", "numeric", "onlynumeric": filterMode = FlxInputText.ONLY_NUMERIC;
			case "alphanum", "alphanumeric", "onlyalphanumeric": filterMode = FlxInputText.ONLY_ALPHANUMERIC;
			case "a", "n", "an":
					throw new Error("FlxUI._loadInputText(): 1 letter values have been deprecated (filter attribute).");
			default: filterMode = FlxInputText.NO_FILTER;
		}
			
		fti.setFormat(the_font, size, color, align);
		fti.forceCase = forceCase;
		fti.filterMode = filterMode;
		border.apply(fti);
		fti.drawFrame();
		ft = fti;
		
		if (data.hasNode.param)
		{
			var params = getParams(data);
			var ihp:IHasParams = cast ft;
			ihp.params = params;
		}
		
		if (H > 0 && ft.height != H)
		{
			if (Std.is(ft, IResizable))
			{
				var r:IResizable = cast ft;
				r.resize(r.width, H);
			}
		}
		
		return ft;
	}

	/**
	 * Takes two XML files and combines them, with "data" overriding duplicate attributes found in "definition"
	 * @param	data		the local data tag
	 * @param	definition	the base definition you are extending
	 * @param	combineUniqueChildren if true, will combine child tags if they are unique. If false, inserts child tags as new ones.
	 * @return
	 */
	
	public static function consolidateData(data:Fast, definition:Fast, combineUniqueChildren:Bool=false):Fast
	{
		if (data == null && definition != null)
		{
			return definition;		//no data? Return the definition;
		}
		if (definition == null)
		{
			return data;			//no definition? Return the original data
		}
		else
		{
			//If there's data and a definition, try to consolidate them
			//Start with the definition data, copy in the local changes
			
			var new_data:Xml = U.copyXml(definition.x);	//Get copy of definition Xml
			
			for (att in data.x.attributes())			//Loop over each attribute in local data
			{
				var val:String = data.att.resolve(att);
				new_data.set(att, val);			//Copy it in
			}
			
			//Make sure the name is the object's name, not the definition's
			new_data.nodeName = data.name;
			if (data.has.name || data.has.id)
			{
				new_data.set("name", U.xml_name(data.x));
			}
			else
			{
				new_data.set("name", "");
			}
			
			for (element in data.x.elements())		//Loop over each node in local data
			{
				var nodeName = element.nodeName;
				var notCombine = !combineUniqueChildren;
				if (combineUniqueChildren)			//if we're supposed to combine it instead of inserting it
				{
					var new_els:Iterator<Xml> = new_data.elementsNamed(nodeName);
					var new_el:Xml = new_els.next();
					
					//if there is only one child node of that name in BOTH the definition AND the target
					if (data.nodes.resolve(nodeName).length == 1 && new_el != null && new_els.hasNext() == false)
					{
						//combine them
						for (att in element.attributes())
						{
							new_el.set(att, element.get(att));
						}
					}
					else
					{
						notCombine = true;
					}
				}
				
				if (notCombine)
				{
					new_data.insertChild(U.copyXml(element), 0);	//Add the node
				}
			}
			return new Fast(new_data);
		}
		return data;
	}
	
	private function _loadRadioGroup(data:Fast):FlxUIRadioGroup
	{
		var frg:FlxUIRadioGroup = null;
		
		var dot_src:String = U.xml_str(data.x, "dot_src", true);
		var radio_src:String = U.xml_str(data.x, "radio_src", true);
		
		var labels:Array<String> = new Array<String>();
		var names:Array<String> = new Array<String>();
		
		var W:Int = cast _loadWidth(data, 11, "radio_width");
		var H:Int = cast _loadHeight(data, 11, "radio_height");
		
		var scrollH:Int = cast _loadHeight(data, 0, "height");
		var scrollW:Int = cast _loadHeight(data, 0, "width");
		
		var labelW:Int = cast _loadWidth(data, 100, "label_width");
		
		for (radioNode in data.nodes.radio)
		{
			var name:String = U.xml_name(radioNode.x);
			var label:String = U.xml_str(radioNode.x, "label");
			
			var context:String = U.xml_str(radioNode.x, "context", true, "ui");
			var code:String = U.xml_str(radioNode.x, "code", true, "");
			label = getText(label,context,true,code);
		
			names.push(name);
			labels.push(label);
		}
		
		names.reverse();		//reverse so they match the order entered in the xml
		labels.reverse();
		
		var y_space:Float = _loadHeight(data, 25, "y_space");
		
		var params:Array<Dynamic> = getParams(data);
		
		
		/*
		 * For resolution independence you might want scaleable or 9-slice scaleable sprites for radio box & dot.
		 * So in this case, if you supply <box> and <dot> nodes instead of "radio_src" and "dot_src", it will
		 * let you load the radio box and dot using the full power of <sprite> and <9slicesprite> nodes.
		 */
		
		var radio_asset:Dynamic = null;
		if (radio_src != "")
		{
			radio_asset = U.gfx(radio_src);
		}
		else if (data.hasNode.box)
		{
			//We have a custom box node
			if (U.xml_str(data.node.box.x, "slice9") != "")
			{
				//It's a 9-slice sprite, load the custom node
				radio_asset = _load9SliceSprite(data.node.box);
			}
			else
			{
				//It's a regular sprite, load the custom node
				radio_asset = _loadSprite(data.node.box);
			}
		}
		
		var dot_asset:Dynamic = null;
		if (dot_src != "")
		{
			dot_asset = U.gfx(dot_src);
		}
		else if (data.hasNode.dot)
		{
			//We have a custom check node
			if (U.xml_str(data.node.dot.x, "slice9") != "")
			{
				//It's a 9-slice sprite, load the custom node
				dot_asset = _load9SliceSprite(data.node.dot);
			}
			else
			{
				//It's a regular sprite, load the custom node
				dot_asset = _loadSprite(data.node.dot);
			}
		}
		
		//if radio_src or dot_src are == "", then leave radio_asset/dot_asset == null, 
		//and FlxUIRadioGroup will default to defaults defined in FlxUIAssets 
		
		var prevOffset:FlxPoint = null;
		var nextOffset:FlxPoint = null;
		
		if (data.hasNode.button)
		{
			for (btnNode in data.nodes.button)
			{
				var name:String = U.xml_name(btnNode.x);
				if (name == "previous" || name == "prev")
				{
					prevOffset = FlxPoint.get(U.xml_f(btnNode.x, "x"),U.xml_f(btnNode.x,"y"));
				}
				else if (name == "next")
				{
					nextOffset = FlxPoint.get(U.xml_f(btnNode.x, "x"),U.xml_f(btnNode.x,"y"));
				}
			}
		}
		
		var noScrollButtons = U.xml_bool(data.x, "scroll_buttons", true) == false;
		
		frg = new FlxUIRadioGroup(0, 0, names, labels, null, y_space, W, H, labelW, "<X> more...", prevOffset, nextOffset, null, null, noScrollButtons);
		frg.params = params;
		
		if (radio_asset != "" && radio_asset != null)
		{
			frg.loadGraphics(radio_asset, dot_asset);
		}
		
		var text_x:Int = Std.int(_loadWidth(data, 0, "text_x"));
		var text_y:Int = Std.int(_loadHeight(data, 0, "text_y"));
		
		var radios = frg.getRadios();
		var i:Int = 0;
		var styleSet:Bool = false;
		
		var radioList = data.x.elementsNamed("radio");
		var radioNode:Xml = null;
		
		for (k in 0...radios.length)
		{
			var fo = radios[(radios.length - 1) - k];
			radioNode = radioList.hasNext() ? radioList.next() : null;
			if (fo != null)
			{
				if (Std.is(fo, FlxUICheckBox))
				{
					var fc:FlxUICheckBox = cast(fo, FlxUICheckBox);
					var t:FlxText = formatButtonText(data, fc);
					if (t != null && styleSet == false)
					{
						var fd = FontDef.copyFromFlxText(t);
						var bd = new BorderDef(t.borderStyle, t.borderColor, t.borderSize, t.borderQuality);
						frg.activeStyle = new CheckStyle(0xffffff, fd, t.alignment, t.color, bd);
						styleSet = true;
					}
					fc.textX = text_x;
					fc.textY = text_y;
					i++;
					if (radioNode != null)
					{
						_loadTooltip(fc, new Fast(radioNode));
					}
				}
			}
		}
		
		if (scrollW != 0)
		{
			frg.fixedSize = true;
			frg.width = scrollW;
		}
		if (scrollH != 0)
		{
			frg.fixedSize = true;
			frg.height = scrollH;
		}
		
		return frg;
	}
	
	private function _loadCheckBox(data:Fast):FlxUICheckBox
	{
		var src:String = "";
		var fc:FlxUICheckBox = null;
		
		var label:String = U.xml_str(data.x, "label");
		var context:String = U.xml_str(data.x, "context", true, "ui");
		var code:String = U.xml_str(data.x, "code", true, "");
		
		var checked:Bool = U.xml_bool(data.x, "checked", false);
		
		label = getText(label,context,true,code);
		
		var labelW:Int = cast _loadWidth(data, 100, "label_width");
		
		var check_src:String = U.xml_str(data.x, "check_src", true);
		var box_src:String = U.xml_str(data.x, "box_src", true);
		
		var slice9:String = U.xml_str(data.x, "slice9", true);
		
		var params:Array<Dynamic> = getParams(data);
		
		var box_asset:Dynamic = null; 
		var check_asset:Dynamic = null;  
		
		/*
		 * For resolution independence you might want scaleable or 9-slice scaleable sprites for box & checkmark.
		 * So in this case, if you supply <box> and <check> nodes instead of "box_src" and "check_src", it will
		 * let you load the box and checkmark using the full power of <sprite> and <9slicesprite> nodes.
		 */
		
		if (box_src != "")
		{
			//Load standard asset src
			box_asset = U.gfx(box_src);
		}
		else if (data.hasNode.box)
		{
			//We have a custom box node
			if (U.xml_str(data.node.box.x, "slice9") != "")
			{
				//It's a 9-slice sprite, load the custom node
				box_asset = _load9SliceSprite(data.node.box);
			}
			else
			{
				//It's a regular sprite, load the custom node
				box_asset = _loadSprite(data.node.box);
			}
		}
		
		if (check_src != "")
		{
			//Load standard check src
			check_asset = U.gfx(check_src);
		}
		else if (data.hasNode.check)
		{
			//We have a custom check node
			if (U.xml_str(data.node.check.x, "slice9") != "")
			{
				//It's a 9-slice sprite, load the custom node
				check_asset = _load9SliceSprite(data.node.check);
			}
			else
			{
				//It's a regular sprite, load the custom node
				check_asset = _loadSprite(data.node.check);
			}
		}
		
		fc = new FlxUICheckBox(0, 0, box_asset, check_asset, label, labelW, params);
		formatButtonText(data, fc);
		
		var text_x:Int = Std.int(_loadWidth(data, 0, "text_x"));
		var text_y:Int = Std.int(_loadHeight(data, 0, "text_y"));
		
		fc.textX = text_x;
		fc.textY = text_y;
		
		fc.text = label;
		
		fc.checked = checked;
		
		return fc;
	}
	
	
	private function _loadDropDownMenu(data:Fast):FlxUIDropDownMenu
	{
		/*
		 *   <dropdown label="Something">
		 *      <data name="thing_1" label="Thing 1"/>
		 *      <data name="thing_2" label="Thing 2"/>
		 *      <data name="1_fish" label="One Fish"/>
		 *      <data name="2_fish" label="Two Fish"/>
		 *      <data name="0xff0000_fish" label="Red Fish"/>
		 *      <data name="0x0000ff_fish" label="Blue Fish"/>
		 *   </dropdown>
		 * 
		 *   <dropdown label="Whatever" back_def="dd_back" panel_def="dd_panel" button_def="dd_button">
		 *      <asset name="a" def="thing_a"/>
		 *      <asset name="b" def="thing_b"/>
		 *      <asset name="c" def="thing_c"/>
		 *   </dropdown> 
		 * 
		 *   <dropdown label="Whatever" back_def="dd_back" panel_def="dd_panel" button_def="dd_button">
		 *      <data name="blah" label="Blah"/>
		 *      <data name="blah2" label="Blah2"/>
		 *      <data name="blah3" label="Blah3"/>
		 *   </dropdown>
		 */
		
		var fud:FlxUIDropDownMenu = null;
		
		var label:String = U.xml_str(data.x, "label");
		var context:String = U.xml_str(data.x, "context", true, "ui");
		var code:String = U.xml_str(data.x, "code", true, "");
		label = getText(label,context,true,code);
		
		var back_def:String = U.xml_str(data.x, "back_def", true);
		var panel_def:String = U.xml_str(data.x, "panel_def", true);
		var button_def:String = U.xml_str(data.x, "button_def", true);
		var label_def:String = U.xml_str(data.x, "label_def", true);
		
		var back_asset:FlxSprite = null;
		var panel_asset:FlxUI9SliceSprite = null;
		var button_asset:FlxUISpriteButton = null;
		var label_asset:FlxUIText = null;
				
		if (back_def != "") {
			back_asset = _loadSprite(getDefinition(back_def));
		}
		
		if (panel_def != "") {
			panel_asset = _load9SliceSprite(getDefinition(panel_def));
		}
		
		if (button_def != "") {
			try{
				button_asset = cast _loadButton(getDefinition(button_def), false, false);
			}catch (e:Error) {
				FlxG.log.add("couldn't loadButton with definition \"" + button_def + "\"");
				button_asset = null;
			}
		}
		
		if (label_def != "") {
			try{
				label_asset = cast _loadText(getDefinition(label_def));
			}catch (e:Error) {
				FlxG.log.add("couldn't loadText with definition \"" + label_def + "\"");
				label_asset = null;
			}
			if (label_asset != null && label != "") {
				label_asset.text = label;
			}
		}
		
		var asset_list:Array<FlxUIButton> = null;
		var data_list:Array<StrNameLabel> = null;
		
		if (data.hasNode.data) {
			for (dataNode in data.nodes.data) {
				if (data_list == null) { 
					data_list = new Array<StrNameLabel>();
				}
				var namel:StrNameLabel = new StrNameLabel(U.xml_str(dataNode.x, "name", true), U.xml_str(dataNode.x, "label"));
				data_list.push(namel);
			}
		}else if (data.hasNode.asset) {
			for (assetNode in data.nodes.asset) {
				if (asset_list == null) {
					asset_list = new Array<FlxUIButton>();
				}
				var def_name:String = U.xml_str(assetNode.x, "def", true);
				var name:String = U.xml_name(assetNode.x);
				var asset:FlxUIButton = null;
				
				try{
					asset = cast _loadButton(getDefinition(def_name), false);
				}catch (e:Error) {
					FlxG.log.add("couldn't loadButton with definition \"" + def_name + "\"");
				}
				
				if (asset != null) {
					asset.name = name;
					if (asset_list == null) {
						asset_list = new Array<FlxUIButton>();
					}
					asset_list.push(asset);
				}
			}
		}
		
		var header = new FlxUIDropDownHeader(120, back_asset, label_asset, button_asset);
		fud = new FlxUIDropDownMenu(0, 0, data_list, null, header, panel_asset, asset_list);// , _onClickDropDown_control);
		
		return fud;
	}
	
	private function _loadTest(data:Fast, nodeName:String="load_if"):Bool {
		var result:Bool = true;
		
		//If this is itself a "<load_if>" tag, return whether or not it passes the test
		if (data.name == nodeName)
		{
			result = _loadTestSub(data);
			if (result == false)
			{
				return false;
			}
		}
		
		//If this is some other tag that CONTAINS a "load_if" tag, make sure all the conditions pass
		if (data.hasNode.resolve(nodeName))
		{
			/*However, for this sort of operation we should ONLY consider "load_if" tags that don't themselves contain children
			 * 
			 <something ...>
			   <stuff .../>
			   <stuff .../>
			   <stuff .../>
			   
			   <load_if .../> <!--some condition, better check it, if it fails, don't load parent object at all-->
			   
			   <load_if ...>  <!--some condition, but if it fails it just means don't load the contents of this BLOCK, you still want the parent object-->
			     <stuff .../>
			     <stuff .../>
			     <stuff .../>
			   </load_if>
			 </something>
			 *
			 */
			for (node in data.nodes.resolve(nodeName))
			{
				if (node.x.firstChild() == null)	//as mentioned above, only run the test if this load_if does not have children
				{
					result = _loadTestSub(node);
					if (result == false)
					{
						return false;
					}
				}
			}
		}
		return result;
	}
	
	private function _loadTestSub(node:Fast):Bool
	{
		var matchValue:Bool = U.xml_bool(node.x, "is", true);
		var match:Bool = matchValue;
		
		//check aspect ratio
		var aspect_ratio:Float = U.xml_f(node.x, "aspect_ratio", -1);
		if (aspect_ratio != -1) {
			match = true;
			var screen_ratio:Float = cast(FlxG.width, Float) / cast(FlxG.height, Float);
			var diff:Float = Math.abs(screen_ratio - aspect_ratio);
			if (node.has.tolerance)
			{
				var tolerance:Float = U.xml_f(node.x, "tolerance", 0.1);
				if (diff > tolerance) {
					match = false;
				}
			}
			else if (node.has.tolerance_plus || node.has.tolerance_minus)
			{
				var tolerance_minus:Float = U.xml_f(node.x, "tolerance_minus", -1);
				var tolerance_plus:Float = U.xml_f(node.x, "tolerance_plus", -1);
				if (screen_ratio > aspect_ratio && tolerance_plus != -1)
				{
					if (diff > tolerance_plus)
					{
						match = false;
					}
				}
				if (screen_ratio < aspect_ratio && tolerance_minus != -1)
				{
					if (diff > tolerance_minus)
					{
						match = false;
					}
				}
			}
			if (match != matchValue) {
				return false;
			}
		}
		
		//check resolution
		var resolution:FlxPoint = U.xml_pt(node.x, "resolution", null);
		if (resolution != null)
		{
			match = true;
			var toleranceRes:FlxPoint = U.xml_pt(node.x, "tolerance", null);
			if (toleranceRes == null) { toleranceRes = new FlxPoint(0, 0); }
			var diffX:Float = Math.abs(resolution.x - FlxG.width);
			var diffY:Float = Math.abs(resolution.y - FlxG.height);
			if (diffX > toleranceRes.x || diffY > toleranceRes.y)
			{
				match = false;
			}
			if (match != matchValue) {
				return false;
			}
		}
		
		//check haxedefs
		var haxeDef:String = U.xml_str(node.x, "haxedef", true, "");
		var haxeVal:Bool = U.xml_bool(node.x, "value", true);
		
		if (haxeDef != "") {
			match = true;
			var defValue:Bool = U.checkHaxedef(haxeDef);
			match = (defValue == haxeVal);
			if (match != matchValue) {
				return false;
			}
		}
		
		//check variable
		var variable:String = U.xml_str(node.x, "variable", false, "");
		var variableType:String = U.xml_str(node.x, "type", true, "string");
		if (variable != "")
		{
			match = true;
			var varData = parseVarValue(variable);
			if (varData != null)
			{
				match = checkVariable(varData.variable, varData.value, variableType, varData.operator);
			}
			if (match != matchValue) {
				return false;
			}
		}
		
		var locale = U.xml_str(node.x, "locale", false, "");
		if (locale != "")
		{
			var locales = [locale];
			var found = false;
			if (locale.indexOf(",") != -1){
				locales = locale.split(",");
			}
			for (l in locales)
			{
				if (_ptr_tongue.locale == l)
				{
					found = true;
				}
			}
			
			if (found != matchValue) {
				return false;
			}
		}
		
		return true;
	}
	
	private function parseVarValue(varString:String):VarValue {
		var arr:Array<String> = ["==", "=", "!=", "!==", "<", ">", "<=", ">="];
		var temp:Array<String>;
		for (op in arr)
		{
			if (varString.indexOf(op) != -1)
			{
				temp = varString.split(op);
				if (temp != null && temp.length == 2)
				{
					return { variable:temp[0], value:temp[1], operator:op };
				}
			}
		}
		return null;
	}
	
	private function _loadLayout(data:Fast):FlxUI
	{
		var name:String = U.xml_str(data.x, "name", true);
		var X:Float = _loadX(data);
		var Y:Float = _loadY(data);
		var _ui:FlxUI = createUI(data);
		_ui.x = X;
		_ui.y = Y;
		_ui.name = name;
		return _ui;
	}
	
	private function addToCleanup(str:String):Void
	{
		if (_assetsToCleanUp == null) return;
		if (_assetsToCleanUp.indexOf(str) == -1)
		{
			_assetsToCleanUp.push(str);
		}
	}
	
	private function addToScaledAssets(str:String):Void
	{
		if (_scaledAssets != null && _scaledAssets.indexOf(str) == -1)
		{
			_scaledAssets.push(str);
		}
	}
	
	private function cleanup():Void
	{
		for (key in _assetsToCleanUp)
		{
			FlxG.bitmap.removeByKey(key);
		}
		_assetsToCleanUp = null;
		_scaledAssets = null;
	}
	
	private function getXML(id:String, extension:String = "xml", getFast:Bool = true, dir = "assets/xml/", getFirstElement:Bool = true):Dynamic
	{
		return U.xml(id, extension, getFast, dir, getFirstElement);
	}
	
	private function newUI(data:Fast = null, ptr:IEventGetter = null, superIndex_:FlxUI = null, tongue_:IFireTongue = null, liveFilePath_:String="", uiVars_:Map<String,String>=null):FlxUI
	{
		return new FlxUI(data, ptr, superIndex_, tongue_, liveFilePath_, uiVars_);
	}
	
	private function createUI(data:Fast):FlxUI
	{
		return newUI(data, this, this, _ptr_tongue, liveFilePath);
	}
	
	private function _loadTabMenu(data:Fast):FlxUITabMenu{
		
		var back_def:Fast = getUseDef(data, "back_def");
		back_def = consolidateData(back_def, data);
		
		var back_type:String = U.xml_str(data.x, "back_type", true, "chrome");
		
		var backSprite:FlxSprite = switch(back_type)
		{
			case "sprite": _loadSprite(back_def);
			case "region": new FlxUIRegion();
			default: _load9SliceSprite(back_def, "tab_menu");
		}
		
		var tab_def:Fast = null;
		
		var stretch_tabs:Bool = U.xml_bool(data.x, "stretch_tabs",false);
		
		var stackToggled:String = "front";
		var stackUntoggled:String = "back";
		
		if (data.hasNode.stacking) {
			stackToggled = U.xml_str(data.node.stacking.x, "toggled", true, "front");
			stackUntoggled = U.xml_str(data.node.stacking.x, "untoggled", true, "back");
		}
		
		var tab_spacing_str:String = U.xml_str(data.x, "spacing", true, "");
		var tab_spacing:Null<Float> = null;
		if (tab_spacing_str != "") {
			tab_spacing = _loadWidth(data, 0, "spacing");
		}
		
		//x/y offsets for tabs
		var tab_x:Float = _loadWidth(data, 0, "tab_x");
		var tab_y:Float = _loadHeight(data, 0, "tab_y");
		var tab_offset = FlxPoint.get(tab_x, tab_y);
		
		var tab_def_str:String = "";
		
		if (data.hasNode.tab) {
			for(tabNode in data.nodes.tab){
				var temp = U.xml_str(tabNode.x, "use_def");
				if (temp != "") { 
					tab_def_str = temp;
				}
			}
			if (tab_def_str != "") {
				tab_def = getDefinition(tab_def_str);
			}else {
				tab_def = data.node.tab;
			}
		}
		
		var list_tabs:Array<IFlxUIButton> = new Array<IFlxUIButton>();
		
		var name:String = "";
		
		if (data.hasNode.tab) {
			for (tab_node in data.nodes.tab) {
				name = U.xml_name(tab_node.x);
				
				if(name != ""){
					var label:String = U.xml_str(tab_node.x, "label");
					var context:String = U.xml_str(tab_node.x, "context", true, "ui");
					var code:String = U.xml_str(tab_node.x, "code", true, "");
					label = getText(label,context,true,code);
					
					label = getText(label,context,true,code);
					
					var tab_info:Fast = consolidateData(tab_node, tab_def);
					var tab:IFlxUIButton = cast _loadButton(tab_info, true, true, "tab_menu");
					tab.name = name;
					list_tabs.push(tab);
					_loadTooltip(tab, tab_info);
				}
			}
		}
		
		if (list_tabs.length > 0) {
			if (tab_def == null || !tab_def.hasNode.text) {
				for (t in list_tabs) {
					if (Std.is(t, FlxUITypedButton))
					{
						var tb:FlxUITypedButton<FlxSprite> = cast t;
						tb.label.color = 0xFFFFFF;
						if (Std.is(tb.label, FlxUIText))
						{
							var labelText:FlxUIText = cast tb.label;
							labelText.setBorderStyle(OUTLINE);
						}
					}
				}
			}
			
			if (tab_def == null || !tab_def.has.width) {	//no tab definition!
				stretch_tabs = true;
				//make sure to stretch the default tab graphics
			}
		}
		
		var tab_stacking:Array<String> = [stackToggled, stackUntoggled];
		
		var fg:FlxUITabMenu = new FlxUITabMenu(backSprite,list_tabs,tab_offset,stretch_tabs,tab_spacing,tab_stacking);
		
		if (data.hasNode.group) {
			for (group_node in data.nodes.group) {
				name = U.xml_name(group_node.x);
				var _ui:FlxUI = newUI(group_node, fg, this, _ptr_tongue);
				if(list_tabs != null && list_tabs.length > 0){
					_ui.y += list_tabs[0].height;
				}
				_ui.name = name;
				fg.addGroup(_ui);
			}
		}
		
		return fg;
	}
	
	private function _loadNumericStepper(data:Fast, setCallback:Bool = true):IFlxUIWidget {
		
		/*
		 * <numeric_stepper step="1" value="0" min="1" max="2" decimals="1">
		 * 		<text/>
		 * 		<plus/>
		 * 		<minus/>
		 * 		<params/>
		 * </numeric_stepper>
		 * 
		 */
		
		var stepSize:Float = U.xml_f(data.x, "step", 1);
		var defaultValue:Float = U.xml_f(data.x, "value", 0);
		var min:Float = U.xml_f(data.x, "min", 0);
		var max:Float = U.xml_f(data.x, "max", 10);
		var decimals:Int = U.xml_i(data.x, "decimals", 0);
		var percent:Bool = U.xml_bool(data.x, "percent");
		var stack:String = U.xml_str(data.x, "stack",true,"");
		if (stack == "") {
			stack = U.xml_str(data.x, "stacking",true,"");
		}
		stack = stack.toLowerCase();
		var stacking:Int;
		
		switch(stack) {
			case "horizontal", "h", "horz":
				stacking = FlxUINumericStepper.STACK_HORIZONTAL;
			case "vertical", "v", "vert":
				stacking = FlxUINumericStepper.STACK_VERTICAL;
			default:
				stacking = FlxUINumericStepper.STACK_HORIZONTAL;
		}
		
		var theText:FlxText = null;
		var buttPlus:FlxUITypedButton<FlxSprite> = null;
		var buttMinus:FlxUITypedButton<FlxSprite> = null;
		var bkg:FlxUISprite = null;
		
		if (data.hasNode.text) {
			theText = cast _loadThing("text", data.node.text);
		}
		if (data.hasNode.plus) {
			buttPlus = cast _loadThing("button", data.node.plus);
		}
		if (data.hasNode.minus) {
			buttMinus = cast _loadThing("button", data.node.minus);
		}
		
		var ns:FlxUINumericStepper = new FlxUINumericStepper(0, 0, stepSize, defaultValue, min, max, decimals, stacking, theText, buttPlus, buttMinus, percent);
		
		if (setCallback) {
			var params:Array<Dynamic> = getParams(data);
			ns.params = params;
		}
		
		return ns;
	}
	
	private function getResizeRatio(data:Fast,defaultAxis:Int=FlxUISprite.RESIZE_RATIO_Y):FlxPoint
	{
		var str:String = U.xml_str(data.x, "resize_ratio_x", true);
		if (str == "")
		{
			str = U.xml_str(data.x, "resize_ratio_y", true);
			if (str == "")
			{
				//neither x nor y supplied, assume default
				var resize_ratio = U.xml_f(data.x, "resize_ratio", -1);
				return new FlxPoint(resize_ratio, defaultAxis);
			}
			else
			{
				//y supplied
				return new FlxPoint(Std.parseFloat(str), FlxUISprite.RESIZE_RATIO_Y);
			}
		}
		else
		{
			//x supplied
			return new FlxPoint(Std.parseFloat(str), FlxUISprite.RESIZE_RATIO_X);
		}
		
		//This should never happen
		return new FlxPoint( -1, -1);
	}
	
	@:access(flixel.addons.ui.FlxUITypedButton)
	private function _loadButton(data:Fast, setCallback:Bool = true, isToggle:Bool = false, load_code:String = ""):IFlxUIWidget
	{
		var src:String = ""; 
		var fb:IFlxUIButton = null;
		
		var resize_ratio:Float = U.xml_f(data.x, "resize_ratio", -1);
		var resize_point:FlxPoint = _loadCompass(data, "resize_point");
		var resize_label:Bool = U.xml_bool(data.x, "resize_label", false);
		
		var label:String = U.xml_str(data.x, "label");
		
		var sprite:FlxUISprite = null;
		var spriteIsAnimated:Bool = false;
		var toggleSprite:FlxUISprite = null;
		if (data.hasNode.sprite)
		{
			for (spriteNode in data.nodes.sprite)
			{
				var forToggle:Bool = isToggle && U.xml_bool(spriteNode.x, "toggle");
				if (forToggle)
				{
					toggleSprite = cast _loadThing("sprite", spriteNode);
				}
				else
				{
					sprite = cast _loadThing("sprite", spriteNode);
				}
				if (spriteNode.hasNode.anim)
				{
					if (sprite.animation.curAnim != null)
					{
						spriteIsAnimated = true;
					}
				}
			}
		}
		
		var context:String = U.xml_str(data.x, "context", true, "ui");
		var code:String = U.xml_str(data.x, "code", true, "");
		
		label = getText(label,context,true,code);
		
		var W:Int = Std.int(_loadWidth(data, 0, "width"));
		var H:Int = Std.int(_loadHeight(data, 0, "height"));
		
		var params:Array<Dynamic> = getParams(data);
		
		var hasImg = false;
		var isGfxBlank = false;
		if (data.hasNode.graphic)
		{
			var graphic = data.node.graphic;
			var img = U.xml_str(graphic.x, "image");
			isGfxBlank = U.xml_bool(graphic.x, "blank");
			hasImg = (img != "");
		}
		
		if (sprite == null)
		{
			var name = U.xml_name(data.x);
			var graphic = data.hasNode.graphic ? data.node.graphic : null;
			
			var loadBlank = false;
			
			var useDefaultGraphic = (data.hasNode.graphic == false);
			if (useDefaultGraphic)
			{
				loadBlank = false;
			}
			else
			{
				if (isGfxBlank || hasImg)
				{
					//optimization: if the thing is blank, or I'm about to provide my own graphic, then skip wasteful 9-slice churn
					loadBlank = true;
				}
			}
			
			fb = new FlxUIButton(0, 0, label, null, useDefaultGraphic, loadBlank);
			var fuib:FlxUIButton = cast fb;
			fuib._autoCleanup = false;
		}
		else
		{
			var tempGroup:FlxSpriteGroup = null;
			
			if (spriteIsAnimated || label != "")
			{
				//If the sprite is animated, or we have a Sprite AND a Label, we package it up in a groupw
				
				tempGroup = new FlxSpriteGroup();
				tempGroup.add(sprite);
				
				if (label != "")
				{
					var labelTxt = new FlxUIText(0, 0, 80, label, 8);
					labelTxt.setFormat(null, 8, 0x333333, "center");
					tempGroup.add(labelTxt);
				}
				
				fb = new FlxUISpriteButton(0, 0, tempGroup);
			}
			else
			{
				fb = new FlxUISpriteButton(0, 0, sprite);
			}
		}
		
		if (fb != null && data != null)
		{
			fb.name = U.xml_name(data.x);
		}
		
		fb.resize_ratio = resize_ratio;
		fb.resize_point = resize_point;
		fb.autoResizeLabel = resize_label;
		
		if (setCallback)
		{
			fb.params = params;
		}
		
		/***Begin graphics loading block***/
		
		if (data.hasNode.graphic)
		{
			var blank:Bool = U.xml_bool(data.node.graphic.x, "blank");
			
			if (blank)
			{
				//load blank
				#if neko
					fb.loadGraphicSlice9(["", "", ""], W, H, null, FlxUI9SliceSprite.TILE_NONE, resize_ratio, false, 0, 0, null);
				#else
					fb.loadGraphicSlice9(["", "", ""], W, H, null, FlxUI9SliceSprite.TILE_NONE, resize_ratio);
				#end
			}
			else
			{
				var graphic_names:Array<FlxGraphicAsset>=null;
				var slice9_names:Array<Array<Int>>=null;
				var frames:Array<Int>=null;
				
				if (isToggle) {
					graphic_names = ["", "", "", "", "", ""];
					slice9_names= [null, null, null, null, null, null];
				}else {
					graphic_names = ["", "", ""];
					slice9_names = [null, null, null];
				}
				
				//dimensions of source 9slice image (optional)
				var src_w:Int = U.xml_i(data.node.graphic.x, "src_w", 0);
				var src_h:Int = U.xml_i(data.node.graphic.x, "src_h", 0);
				var tile:Int = _loadTileRule(data.node.graphic);
				
				//custom frame indeces array (optional)
				var frame_str:String = U.xml_str(data.node.graphic.x, "frames",true);
				if (frame_str != "") {
					frames = new Array<Int>();
					var arr = frame_str.split(",");
					for (numstr in arr) {
						frames.push(Std.parseInt(numstr));
					}
				}
				
				if (data.hasNode.scale_src)
				{
					var scale_:Float = _loadScale(data.node.scale_src, -1);
					var min:Float = U.xml_f(data.node.scale_src.x, "min", 0);
					var scale_x:Float = scale_ != -1 ? scale_ : _loadScaleX(data.node.scale_src,-1);
					var scale_y:Float = scale_ != -1 ? scale_ : _loadScaleY(data.node.scale_src, -1);
					if (scale_ < min) scale_ = min;
					if (scale_x < min) scale_x = min;
					if (scale_y < min) scale_y = min;
				}
				
				for (graphicNode in data.nodes.graphic) {
					var graphic_name:String = U.xml_name(graphicNode.x);
					var image:String = U.xml_str(graphicNode.x, "image");
					var slice9:Array<Int> = FlxStringUtil.toIntArray(U.xml_str(graphicNode.x, "slice9"));
					tile = _loadTileRule(graphicNode);
					
					var toggleState:Bool = U.xml_bool(graphicNode.x, "toggle");
					toggleState = toggleState && isToggle;
					
					var igfx:String = U.gfx(image);
					
					switch(graphic_name)
					{
						case "inactive", "", "normal", "up": 
							if (image != "") { 
								if (!toggleState) {
									graphic_names[0] = loadScaledSrc(graphicNode,"image","scale_src");
								}else {
									graphic_names[3] = loadScaledSrc(graphicNode,"image","scale_src");
								}
							}
							if(!toggleState)
							{
								slice9_names[0] = load9SliceSprite_scaleSub(slice9, graphicNode, graphic_names[0], "image");
							}
							else
							{
								slice9_names[3] = load9SliceSprite_scaleSub(slice9, graphicNode, graphic_names[3], "image");
							}
						case "active", "highlight", "hilight", "over", "hover": 
							if (image != "") { 
								if (!toggleState) {
									graphic_names[1] = loadScaledSrc(graphicNode,"image","scale_src");
								}else {
									graphic_names[4] = loadScaledSrc(graphicNode,"image","scale_src");
								}
							}
							if(!toggleState)
							{
								slice9_names[1] = load9SliceSprite_scaleSub(slice9, graphicNode, graphic_names[1], "image");
							}
							else
							{
								slice9_names[4] = load9SliceSprite_scaleSub(slice9, graphicNode, graphic_names[4], "image");
							}
						case "down", "pressed", "pushed":
							if (image != "") { 
								if(!toggleState){
									graphic_names[2] = loadScaledSrc(graphicNode,"image","scale_src");
								}else {
									graphic_names[5] = loadScaledSrc(graphicNode,"image","scale_src");
								}
							}
							if(!toggleState)
							{
								slice9_names[2] = load9SliceSprite_scaleSub(slice9, graphicNode, graphic_names[2], "image");
							}
							else
							{
								slice9_names[5] = load9SliceSprite_scaleSub(slice9, graphicNode, graphic_names[5], "image");
							}
						case "all":
							var tilesTall:Int = isToggle ? 6 : 3;
							
							var temp:BitmapData = null;
							
							//if src_h was provided, manually calculate tilesTall in case it's non-standard (like 4 for instance, like TDRPG uses)
							if (src_h != 0)
							{
								var temp:BitmapData = U.getBmp(igfx);
								tilesTall = Std.int(temp.height / src_h);
							}
							
							if (image != "") { 
								graphic_names = [loadScaledSrc(graphicNode, "image", "scale_src", 1, tilesTall)];
							}
							
							slice9_names = [load9SliceSprite_scaleSub(slice9, graphicNode, graphic_names[0], "image")];
							
							//look at the scaled source to get the absolute correct final values
							temp = U.getBmp(graphic_names[0]);
							src_w = temp.width;
							src_h = Std.int(temp.height / tilesTall);
					}
					
					if (graphic_names[0] != "") {
						if (graphic_names.length >= 3) {
							if (graphic_names[1] == "") {		//"over" is undefined, grab "up"
								graphic_names[1] = graphic_names[0];
							}
							if (graphic_names[2] == "") {		//"down" is undefined, grab "over"
								graphic_names[2] = graphic_names[1];
							}
							if (graphic_names.length >= 6) {	//toggle states
								if (graphic_names[3] == "") {	//"up" undefined, grab "up" (untoggled)
									graphic_names[3] = graphic_names[0];
								}
								if (graphic_names[4] == "") {	//"over" grabs "over"
									graphic_names[4] = graphic_names[1];
								}
								if (graphic_names[5] == "") {	//"down" grabs "down"
									graphic_names[5] = graphic_names[2];
								}
							}
						}
					}
				}
				
				if (slice9_names == null || (slice9_names.length == 1 && slice9_names[0] == null))
				{
					//load conventionally, and disallow resizing since the asset is not resizable
					if (graphic_names != null && graphic_names.length == 1)
					{
						fb.loadGraphicsUpOverDown(graphic_names[0], isToggle);
						fb.allowResize = false;
					}
					else
					{
						fb.loadGraphicsMultiple(graphic_names);
						fb.allowResize = false;
					}
				}
				else
				{
					//load 9-slice
					fb.loadGraphicSlice9(graphic_names, W, H, slice9_names, tile, resize_ratio, isToggle, src_w, src_h, frames);
				}
			}
		}
		else
		{
			if (load_code == "tab_menu"){
				//load default tab menu graphics
				var graphic_names:Array<FlxGraphicAsset> = [FlxUIAssets.IMG_TAB_BACK, FlxUIAssets.IMG_TAB_BACK, FlxUIAssets.IMG_TAB_BACK, FlxUIAssets.IMG_TAB, FlxUIAssets.IMG_TAB, FlxUIAssets.IMG_TAB];
				var slice9_tab:Array<Int> = FlxStringUtil.toIntArray(FlxUIAssets.SLICE9_TAB);
				var slice9_names:Array<Array<Int>> = [slice9_tab, slice9_tab, slice9_tab, slice9_tab, slice9_tab, slice9_tab];
				
				//These is/cast checks are here to avoid weeeeird bugs on neko target, which suggests they might also crop up elsewhere
				if (Std.is(fb, FlxUIButton)) {
					var fbui:FlxUIButton = cast fb;
					fbui.loadGraphicSlice9(graphic_names, W, H, slice9_names, FlxUI9SliceSprite.TILE_NONE, resize_ratio, isToggle);
				}else if (Std.is(fb, FlxUISpriteButton)) {
					var fbuis:FlxUISpriteButton = cast fb;
					fbuis.loadGraphicSlice9(graphic_names, W, H, slice9_names, FlxUI9SliceSprite.TILE_NONE, resize_ratio, isToggle);
				}else {
					fb.loadGraphicSlice9(graphic_names, W, H, slice9_names, FlxUI9SliceSprite.TILE_NONE, resize_ratio, isToggle);
				}
			}else{
				//load default graphics
				if (W <= 0) W = 80;
				if (H <= 0) H = 20;
				fb.loadGraphicSlice9(null, W, H, null, FlxUI9SliceSprite.TILE_NONE, resize_ratio, isToggle);
			}
		}
		
		/***End graphics loading block***/
		
		if (sprite == null)
		{
			if (data != null && data.hasNode.text) {
				formatButtonText(data, fb);
			}else {
				if (load_code == "tab_menu") {
					fb.up_color = 0xffffff;
					fb.down_color = 0xffffff;
					fb.over_color = 0xffffff;
					fb.up_toggle_color = 0xffffff;
					fb.down_toggle_color = 0xffffff;
					fb.over_toggle_color = 0xffffff;
				}
				else
				{
					// Center sprite icon 
					fb.centerLabel();
				}
			}
		}else {
			fb.centerLabel();
		}
		
		if (sprite != null && label != "") {
			if(data != null && data.hasNode.text){
				formatButtonText(data, fb);
			}
		}
		
		var text_x:Int = 0;
		var text_y:Int = 0;
		if (data.x.get("text_x") != null) {
			text_x =  Std.int(_loadWidth(data, 0, "text_x"));
		}else if (data.x.get("label_x") != null) {
			text_x =  Std.int(_loadWidth(data, 0, "label_x"));
		}
		if (data.x.get("text_y") != null) {
			text_y = Std.int(_loadHeight(data, 0, "text_y")); 
		}else if (data.x.get("label_y") != null) {
			text_y = Std.int(_loadHeight(data, 0, "label_y"));
		}
		
		if (Std.is(fb, FlxUISpriteButton))
		{
			var fbs:FlxUISpriteButton = cast fb;
			if(Std.is(fbs.label,FlxSpriteGroup)){
				var g:FlxSpriteGroup = cast fbs.label;
				for (sprite in g.group.members) 
				{
					if (Std.is(sprite, FlxUIText)) 
					{
						//label offset has already been 'centered,' this adjust from there:
						sprite.offset.x -= text_x;
						sprite.offset.y -= text_y;
						break;
					}
				}
			}else {
				fbs.label.offset.x -= text_x;
				fbs.label.offset.y -= text_y;
				if (toggleSprite != null) {
					toggleSprite.offset.x -= text_x;
					toggleSprite.offset.y -= text_y;
				}
			}
		}
		else
		{
			var fbu:FlxUIButton = cast fb;
			//label offset has already been 'centered,' this adjust from there:
			fbu.label.offset.x -= text_x;
			fbu.label.offset.y -= text_y;
		}
		
		if (sprite != null && toggleSprite != null) {
			fb.toggle_label = toggleSprite;
		}
		
		if (Std.is(fb, FlxUITypedButton))
		{
			var fuitb:FlxUITypedButton<FlxSprite> = cast fb;
			if (fuitb._assetsToCleanup != null)
			{
				for (key in fuitb._assetsToCleanup)
				{
					addToCleanup(key);
				}
			}
		}
		
		return fb;
	}
	
	private static inline function _loadBitmapRect(source:String,rect_str:String):BitmapData {
		var b1:BitmapData = Assets.getBitmapData(U.gfx(source));
		var r:Rectangle = FlxUI9SliceSprite.getRectFromString(rect_str);
		var b2:BitmapData = new BitmapData(Std.int(r.width), Std.int(r.height), true, 0x00ffffff);
		b2.copyPixels(b1, r, new Point(0, 0));
		return b2;
	}
	
	private function _loadRegion(data:Fast):FlxUIRegion
	{
		var bounds = calcMaxMinSize(data);
		
		var w:Int = Std.int(_loadWidth(data));
		var h:Int = Std.int(_loadHeight(data));
		
		if (bounds != null)
		{
			var pt = U.conformToBounds(new Point(w, h), bounds);
			w = Std.int(pt.x);
			h = Std.int(pt.y);
		}
		
		var vis:Bool = U.xml_bool(data.x, "visible", true);
		var reg = new FlxUIRegion(0, 0, w, h);
		reg.visible = vis;
		return reg;
	}
	
	private function _load9SliceSprite(data:Fast, load_code:String = ""):FlxUI9SliceSprite
	{
		var src:String = "";
		var f9s:FlxUI9SliceSprite = null;
		
		var thename = U.xml_name(data.x);
		
		var resize:FlxPoint = getResizeRatio(data);
		
		var resize_ratio:Float = resize.x;
		var resize_point:FlxPoint = _loadCompass(data, "resize_point");
		var resize_ratio_axis:Int = Std.int(resize.y);
		
		var subSprites:Bool = U.xml_bool(data.x, "sub_sprites", false);
		
		var bounds: { min_width:Float, min_height:Float, 
					  max_width:Float, max_height:Float } = calcMaxMinSize(data);
		
		src = U.xml_gfx(data.x, "src");
		
		var hasScaledSrc:Bool = data.hasNode.scale_src;
		if (hasScaledSrc)
		{
			//We are scaling a base image first BEFORE we 9-slice scale it. Advanced trick!
			//Load that first at the appropriate scale and cache it
			var origSrc = src;
			
			src = loadScaledSrc(data, "src", "scale_src");
			
			if (src != origSrc)
			{
				addToCleanup(origSrc);
			}
		}
		
		if (src == "") { src = null; }
		
		if (src == null)
		{
			if (load_code == "tab_menu")
			{
				src = FlxUIAssets.IMG_CHROME_FLAT;
			}
		}
		
		var rc:Rectangle;
		var rect_w:Int = Std.int(_loadWidth(data));
		var rect_h:Int = Std.int(_loadHeight(data));
		
		if (bounds != null)
		{
			if (rect_w < bounds.min_width) { rect_w = Std.int(bounds.min_width); }
			else if (rect_w > bounds.max_width) { rect_w = cast bounds.max_width; }
			
			if (rect_h < bounds.min_height) { rect_h = Std.int(bounds.min_height); }
			else if (rect_h > bounds.max_height) { rect_h = Std.int(bounds.max_height); }
		}
		if (rect_w == 0 || rect_h == 0)
		{
			return null;
		}
		
		var rc:Rectangle = new Rectangle(0, 0, rect_w, rect_h);
		
		var slice9:Array<Int> = FlxStringUtil.toIntArray(U.xml_str(data.x, "slice9"));
		
		var srcId:String = "";
		var srcGraphic:Dynamic = src;
		
		if (hasScaledSrc)
		{
			slice9 = load9SliceSprite_scaleSub(slice9, data, src);
			
			srcId = src;
			srcGraphic = FlxG.bitmap.get(src);
		}
		
		var smooth:Bool = U.xml_bool(data.x, "smooth", false);
		
		var tile:Int = _loadTileRule(data);
		
		f9s = new FlxUI9SliceSprite(0, 0, srcGraphic, rc, slice9, tile, smooth, srcId, resize_ratio, resize_point, resize_ratio_axis, false, subSprites);
		
		return f9s;
	}
	
	function load9SliceSprite_scaleSub(slice9:Array<Int>,data:Fast,src:String,srcString:String="src"):Array<Int>
	{
		//Figure out what effective scale we are using for the scaled source material
		var origSrc = U.xml_gfx(data.x, srcString);
		
		if (src == origSrc) return slice9;
		
		var srcAsset:BitmapData = FlxG.bitmap.checkCache(src) ? FlxG.bitmap.get(src).bitmap : null;
		
		if (srcAsset == null) srcAsset = Assets.getBitmapData(origSrc);
		
		var origAsset = Assets.getBitmapData(origSrc);
		var srcScaleFactorX = srcAsset.width / origAsset.width;
		var srcScaleFactorY = srcAsset.height / origAsset.height;
		
		if (Math.abs(1.0 - srcScaleFactorX) <= 0.001 && Math.abs(1.0-srcScaleFactorY) <= 0.001)
		{
			return slice9;
		}
		
		if (slice9 != null)
		{
			//Scale the 9-slice boundaries by the same amount
			slice9[0] = Std.int(slice9[0] * srcScaleFactorX);
			slice9[1] = Std.int(slice9[1] * srcScaleFactorY);
			
			var widthDiff = (origAsset.width - slice9[2]);
			var heightDiff = (origAsset.height - slice9[3]);
			
			widthDiff = Std.int(widthDiff * srcScaleFactorX);
			heightDiff = Std.int(heightDiff * srcScaleFactorY);
			
			slice9[2] = Std.int(srcAsset.width - widthDiff);
			slice9[3] = Std.int(srcAsset.height - heightDiff);
		}
		return slice9;
	}
	
	private inline function _loadTileRule(data:Fast):Int {
		var tileStr:String = U.xml_str(data.x, "tile", true,"");
		var tile:Int = FlxUI9SliceSprite.TILE_NONE;
		switch(tileStr) {
			case "true", "both", "all", "hv", "vh": tile = FlxUI9SliceSprite.TILE_BOTH;
			case "h", "horizontal": tile = FlxUI9SliceSprite.TILE_H;
			case "v", "vertical": tile = FlxUI9SliceSprite.TILE_V;
		}
		return tile;
	}
	
	private function _loadBox(data:Fast):FlxUIGroup
	{
		var src:String = ""; 
		var fs:FlxUIGroup = null;
		
		var thickness:Int = Std.int(_loadWidth(data, 1, "thickness"));
		
		var bounds: { min_width:Float, min_height:Float, 
					  max_width:Float, max_height:Float } = calcMaxMinSize(data);
		
		if (bounds == null) {
			bounds = { min_width:Math.NEGATIVE_INFINITY, min_height:Math.NEGATIVE_INFINITY, max_width:Math.POSITIVE_INFINITY, max_height:Math.POSITIVE_INFINITY };
		}
		
		var W:Int = Std.int(_loadWidth(data));
		var H:Int = Std.int(_loadHeight(data));
		
		if (bounds != null)
		{
			if (W < bounds.min_width) { W = Std.int(bounds.min_width); }
			else if (W > bounds.max_width) { W = Std.int(bounds.max_width); }
			if (H < bounds.min_height) { H = Std.int(bounds.max_height); }
			else if (H > bounds.max_height) { H = Std.int(bounds.max_height);}
		}
		
		var cstr:String = U.xml_str(data.x, "color", true, "0xff000000");
		var C:FlxColor = 0;
		if (cstr != "")
		{
			C = U.parseHex(cstr, true);
		}
		
		fs = new FlxUIGroup(0, 0);
		
		var key = W + "x" + H + ":" + C + ":" + thickness;
		
		var top = new FlxSprite().makeGraphic(1, 1, FlxColor.WHITE, false, key);
		top.scale.set(W, thickness);
		top.updateHitbox();
		
		var bottom = new FlxSprite().makeGraphic(1, 1, FlxColor.WHITE, false, key);
		bottom.scale.set(W, thickness);
		bottom.updateHitbox();
		
		var left = new FlxSprite().makeGraphic(1, 1, FlxColor.WHITE, false, key);
		left.scale.set(thickness, H);
		left.updateHitbox();
		
		var right = new FlxSprite().makeGraphic(1, 1, FlxColor.WHITE, false, key);
		right.scale.set(thickness, H);
		right.updateHitbox();
		
		top.color = C;
		bottom.color = C;
		left.color = C;
		right.color = C;
		
		fs.add(top);
		fs.add(bottom);
		fs.add(left);
		fs.add(right);
		
		top.x = 0;
		top.y = 0;
		bottom.x = 0;
		bottom.y = H - bottom.height;
		left.x = 0;
		left.y = 0;
		right.x = W - right.width;
		right.y = 0;
		
		return fs;
	}
	
	private function _loadLine(data:Fast):FlxUILine
	{
		var src:String = ""; 
		
		var axis:String = U.xml_str(data.x, "axis", true, "horizontal");
		var thickness:Int = Std.int(_loadWidth(data, -1, "thickness"));
		
		var bounds: { min_width:Float, min_height:Float, 
					  max_width:Float, max_height:Float } = calcMaxMinSize(data);
		
		if (bounds == null) {
			bounds = { min_width:1, min_height:1, max_width:Math.POSITIVE_INFINITY, max_height:Math.POSITIVE_INFINITY };
		}
		switch(axis) {
				case "h", "horz", "horizontal":	bounds.max_height = thickness; bounds.min_height = thickness;
				case "v", "vert", "vertical":	bounds.max_width = thickness; bounds.min_width = thickness;
		}
		
		var W:Int = Std.int(_loadWidth(data));
		var H:Int = Std.int(_loadHeight(data));
		
		if(bounds != null){
			if (W < bounds.min_width) { W = Std.int(bounds.min_width); }
			else if (W > bounds.max_width) { W = Std.int(bounds.max_width); }
			if (H < bounds.min_height) { H = Std.int(bounds.max_height); }
			else if (H > bounds.max_height) { H = Std.int(bounds.max_height);}
		}

		var cstr:String = U.xml_str(data.x, "color", true, "0xff000000");
		var C:Int = 0;
		if (cstr != "") {
			C = U.parseHex(cstr, true);
		}
		
		var lineAxis:LineAxis = (axis == "horizontal") ? LineAxis.HORIZONTAL : LineAxis.VERTICAL;
		var lineLength:Float = (lineAxis == LineAxis.HORIZONTAL) ? W : H;
		var lineThickness:Float = thickness != -1 ? thickness : (lineAxis == LineAxis.HORIZONTAL) ? H : W;
		
		var fl = new FlxUILine(0, 0, lineAxis, lineLength, lineThickness, C);
		
		return fl;
	}
	
	private function _loadBar(data:Fast):FlxUIBar
	{
		var fb:FlxUIBar = null;
		
		var style:FlxBarStyle = {
			filledColors:null,
			emptyColors:null,
			
			chunkSize:null,
			gradRotation:null,
			
			filledColor:null,
			emptyColor:null,
			borderColor:null,
			
			filledImgSrc:"",
			emptyImgSrc:""
		}
		
		var bounds: { min_width:Float, min_height:Float, 
					  max_width:Float, max_height:Float } = calcMaxMinSize(data);
		
		var W:Int = Std.int(_loadWidth(data,-1));
		var H:Int = Std.int(_loadHeight(data,-1));
		
		var direction:String = U.xml_str(data.x, "fill_direction", true);
		var fillDir:FlxBarFillDirection = FlxBarFillDirection.TOP_TO_BOTTOM;
		
		switch(direction)
		{
			case "left_to_right": fillDir = FlxBarFillDirection.LEFT_TO_RIGHT;
			case "right_to_left": fillDir = FlxBarFillDirection.RIGHT_TO_LEFT;
			case "top_to_bottom": fillDir = FlxBarFillDirection.TOP_TO_BOTTOM;
			case "bottom_to_top": fillDir = FlxBarFillDirection.BOTTOM_TO_TOP;
			case "horizontal_inside_out": fillDir = FlxBarFillDirection.HORIZONTAL_INSIDE_OUT;
			case "horizontal_outside_in": fillDir = FlxBarFillDirection.HORIZONTAL_OUTSIDE_IN;
			case "vertical_inside_out": fillDir = FlxBarFillDirection.VERTICAL_INSIDE_OUT;
			case "vertical_outside_in": fillDir = FlxBarFillDirection.VERTICAL_OUTSIDE_IN;
			default: fillDir = FlxBarFillDirection.LEFT_TO_RIGHT;
		}
		
		var parentRefStr:String = U.xml_str(data.x, "parent_ref", true);
		var parentRef:IFlxUIWidget = parentRefStr != "" ? getAsset(parentRefStr) : null;
		var variableName:String = U.xml_str(data.x, "variable");
		
		var value:Float = U.xml_f(data.x, "value", -1);
		
		var min:Float = U.xml_f(data.x, "min", 0);
		var max:Float = U.xml_f(data.x, "max", 100);
		
		if (value == -1)
		{
			value = max;
		}
		
		style.borderColor = U.xml_color(data.x, "border_color");
		var showBorder:Bool = style.borderColor != null;
		
		style.filledColor = U.xml_color(data.x, "filled_color");
		if (style.filledColor == null)
		{
			style.filledColor = U.xml_color(data.x, "color");
		}
		
		style.emptyColor = U.xml_color(data.x, "empty_color");
		
		style.filledColors  = U.xml_colorArray(data.x, "filled_colors");
		style.emptyColors = U.xml_colorArray(data.x, "empty_colors");
		if (style.filledColors == null)
		{
			style.filledColors = U.xml_colorArray(data.x, "colors");
		}
		
		style.filledImgSrc = loadScaledSrc(data,"src_filled");
		style.emptyImgSrc = loadScaledSrc(data,"src_empty");
		if (style.filledImgSrc == "")
		{
			style.filledImgSrc = loadScaledSrc(data,"src");
		}
		
		style.chunkSize = U.xml_i(data.x, "chunk_size",1);
		style.gradRotation = U.xml_i(data.x, "rotation",90);
		
		if (style.filledImgSrc == "" && style.filledColor == null && style.filledColors == null)
		{
			style.filledColor = FlxColor.RED;	//default to a nice plain filled red bar
		}
		
		if (W == -1 && H == -1)	//If neither Width nor Height is supplied, create with default size
		{
			fb = new FlxUIBar(0, 0, fillDir, 100, 10, parentRef, variableName, min, max, showBorder);
		}
		else					//If Width or Height or both is/are supplied, create at the given size
		{
			fb = new FlxUIBar(0, 0, fillDir, W, H, parentRef, variableName, min, max, showBorder);
		}
		
		fb.style = style;
		fb.resize(fb.barWidth, fb.barHeight);
		
		fb.value = value;
		
		return fb;
	}
	
	private function _loadSprite(data:Fast):FlxUISprite
	{
		var src:String = ""; 
		var fs:FlxUISprite = null;
		
		var scalable = U.xml_bool(data.x, "scalable", false);
		
		var isAnimated = data.hasNode.anim;
		var frameCount:Int = 1;
		if (isAnimated)
		{
			frameCount = Std.int(U.xml_i(data.node.anim.x, "frame_count", 1));
		}
		
		src = loadScaledSrc(data, "src", "scale", frameCount, 1);
		
		var bounds: { min_width:Float, min_height:Float, 
					  max_width:Float, max_height:Float } = calcMaxMinSize(data);
		
		var resize:FlxPoint = getResizeRatio(data,FlxUISprite.RESIZE_RATIO_UNKNOWN);
		  
		var resize_ratio:Float = resize.x;
		var resize_ratio_axis:Int = Std.int(resize.y);
		var resize_point:FlxPoint = _loadCompass(data, "resize_point");
		
		var W:Int = Std.int(_loadWidth(data,-1));
		var H:Int = Std.int(_loadHeight(data,-1));
		
		if (bounds != null)
		{
			if (W < bounds.min_width) { W = Std.int(bounds.min_width); }
			else if (W > bounds.max_width) { W = Std.int(bounds.max_width); }
			if (H < bounds.min_height) { H = Std.int(bounds.max_height); }
			else if (H > bounds.max_height) { H = Std.int(bounds.max_height);}
		}
		
		var frameWidth:Int = 0;
		var frameHeight:Int = 0;
		if (isAnimated)
		{
			frameWidth = Std.int(_loadWidth(data.node.anim, 0, "frame_width"));
			frameHeight = Std.int(_loadHeight(data.node.anim, 0, "frame_height"));
		}
		
		if (src != "")
		{
			if (W == -1 && H == -1)	//If neither Width nor Height is supplied, return the sprite as-is
			{
				fs = new FlxUISprite(0, 0);
				fs.loadGraphic(src, isAnimated, frameWidth, frameHeight);
			}
			else					//If Width or Height or both is/are supplied, do some scaling
			{
				//If an explicit resize aspect ratio is supplied AND either width or height is undefined
				if (resize_ratio != -1 && (W == -1 || H == -1))
				{
					//Infer the correct axis depending on which property was not defined
					if (resize_ratio_axis == FlxUISprite.RESIZE_RATIO_UNKNOWN)
					{
						if (W == -1) { resize_ratio_axis = FlxUISprite.RESIZE_RATIO_X; }
						if (H == -1) { resize_ratio_axis = FlxUISprite.RESIZE_RATIO_Y; }
					}
					
					//Infer the correct scale of the undefined value depending on the resize aspect ratio
					if (resize_ratio_axis == FlxUISprite.RESIZE_RATIO_Y)
					{
						H = cast W * (1 / resize_ratio);
					}
					else if (resize_ratio_axis == FlxUISprite.RESIZE_RATIO_X)
					{
						W = cast H * (1 / resize_ratio);
					}
				}
				
				var smooth = loadSmooth(data, true);
				
				if (!scalable)
				{
					fs = new FlxUISprite(0, 0);
					var imgSrc = "";
					var imgFrameWidth = frameWidth;
					var imgFrameHeight = frameHeight;
					if (isAnimated)
					{
						var testAsset:BitmapData = null;
						if (FlxG.bitmap.checkCache(src))
						{
							var gfx = FlxG.bitmap.get(src);
							if (gfx != null)
							{
								testAsset = gfx.bitmap;
							}
						}
						if(testAsset == null) testAsset = Assets.getBitmapData(src);
						var testScale = H / testAsset.height;
						var tileW = Std.int(frameWidth * testScale);
						var tileH = Std.int(frameHeight * testScale);
						imgSrc = U.scaleAndStoreTileset(src, testScale, frameWidth, frameHeight, tileW, tileH, true);
						imgFrameHeight = tileH;
						imgFrameWidth = tileW;
					}
					else
					{
						imgSrc = U.loadScaledImage(src, W, H, smooth);
					}
					fs.loadGraphic(imgSrc, isAnimated, imgFrameWidth, imgFrameHeight);
				}
				else
				{
					fs = new FlxUISprite(0, 0);
					fs.loadGraphic(src, isAnimated, frameWidth, frameHeight);
					fs.scale_on_resize = true;
					fs.antialiasing = smooth;
					fs.resize(W, H);
				}
			}
		}
		else
		{
			var cstr:String = U.xml_str(data.x, "color");
			var C:Int = 0;
			if (cstr != "")
			{
				C = U.parseHex(cstr, true);
			}
			fs = new FlxUISprite(0, 0);
			fs.makeGraphic(W, H, C);
		}
		
		fs.scale_on_resize = scalable;
		fs.resize_point = resize_point;
		fs.resize_ratio = resize_ratio;
		fs.resize_ratio_axis = resize_ratio_axis;
		
		if (isAnimated)
		{
			var frames:Array<Int> = U.xml_iArray(data.node.anim.x, "frames");
			if (frames != null && frames.length > 0)
			{
				var frameRate:Int = U.xml_i(data.node.anim.x, "frame_rate", 0);
				var looped:Bool = U.xml_bool(data.node.anim.x, "looped", true);
				fs.animation.add("default", frames, frameRate, looped);
				fs.animation.play("default", true);
			}
		}
		
		return fs;
	}
	
	private function loadSmooth(scaleNode:Fast, defaultValue:Bool):Bool
	{
		var defaultStr:String = defaultValue ? "true" : "false";
		var smoothStr:String = U.xml_str(scaleNode.x, "smooth", true, defaultStr);
		if (smoothStr == "")
		{
			smoothStr = U.xml_str(scaleNode.x, "antialias", true, defaultStr);
		}
		return U.boolify(smoothStr);
	}
	
	/**
	 * For grabbing a resolution-specific version of an image src and dynamically scaling (and caching) it as necessary
	 * @param	data	the xml node in question
	 * @return	the unique key of the scaled bitmap
	 */
	
	private function loadScaledSrc(data:Fast, attName:String="src", scaleName:String="scale", tilesWide:Int=1, tilesTall:Int=1):String
	{
		var src:String = U.xml_str(data.x, attName);					//get the original src
		if (data.hasNode.resolve(scaleName))
		{
			for (scaleNode in data.nodes.resolve(scaleName))
			{
				var min:Float = U.xml_f(scaleNode.x, "min");
				var ratio:Float = U.xml_f(scaleNode.x, "screen_ratio", -1);
				var tolerance:Float = U.xml_f(scaleNode.x, "tolerance", 0.1);
				var actualRatio:Float = FlxG.width / FlxG.height;
				
				//check if our screen ratio is within bounds
				if (ratio < 0 || (ratio > 0 && Math.abs(ratio - actualRatio) <= tolerance))
				{
					var suffix:String = U.xml_str(scaleNode.x, "suffix");
					var srcSuffix:String = (src + suffix);					//add the proper suffix, so "asset"->"asset_16x9"
					var testAsset:BitmapData = null;
					var scale_:Float = -1;
					var smooth = loadSmooth(scaleNode, true);
					
					var to_height:Float = _loadHeight(scaleNode, -1, "to_height");
					
					if (to_height != -1)
					{
						var testAsset = U.getBmp(U.gfx(src));
						if (testAsset != null)
						{
							scale_ = to_height / testAsset.height;
						}
					}
					else
					{
						scale_ = _loadScale(scaleNode, -1);
						if (scale_ == -1)
						{
							scale_ = _loadScale(scaleNode, -1, "value");
						}
					}
					
					var scale_x:Float = scale_ != -1 ? scale_ : _loadScaleX(scaleNode, -1);
					var scale_y:Float = scale_ != -1 ? scale_ : _loadScaleY(scaleNode, -1);
					
					if (scale_ < min) scale_ = min;
					if (scale_x < min) scale_x = min;
					if (scale_y < min) scale_y = min;
					
					var sw:Float = 0;
					var sh:Float = 0;
					
					if(scale_x > 0 && scale_y > 0)			//if we found scale_x / scale_y values...
					{
						if (scale_x <= 0) scale_x = 1.0;
						if (scale_y <= 0) scale_y = 1.0;
						
						sw = _loadWidth(scaleNode, -1);
						sh = _loadHeight(scaleNode, -1);
						
						if (sw == -1 || sh == -1)
						{
							testAsset = Assets.getBitmapData(U.gfx(src));
							if (testAsset == null){
								break;
							}
							sw = testAsset.width;
							sh = testAsset.height;
						}
						
						sw *= scale_x;
						sh *= scale_y;
						
					}
					else
					{
						sw = _loadWidth(scaleNode, -1);
						sh = _loadHeight(scaleNode, -1);
					}
					
					if (sw != 0 && sh != 0)
					{
						if (tilesTall > 1 || tilesWide > 1)
						{
							var gfxSrc = U.gfx(src);
							if (FlxG.bitmap.checkCache(gfxSrc))
							{
								testAsset = FlxG.bitmap.get(gfxSrc).bitmap;
							}
							else
							{
								testAsset = Assets.getBitmapData(gfxSrc);
							}
							var str = U.scaleAndStoreTileset(U.gfx(srcSuffix), scale_y, Std.int(testAsset.width / tilesWide), Std.int(testAsset.height / tilesTall), Std.int(sw / tilesWide), Std.int(sh / tilesTall), smooth);
							addToScaledAssets(str);
							return str;
						}
						else
						{
							var str = U.loadScaledImage(srcSuffix, sw, sh, smooth);
							addToScaledAssets(str);
							return str;
						}
					}
					break;						//stop on the first resolution test that passes
				}
			}
		}
		return U.xml_gfx(data.x, attName); 		//no resolution tag found, just return original src
	}
	
	/*private function getMatrix():Matrix {
		if (_matrix == null) {
			_matrix = new Matrix();
		}
		return _matrix;
	}*/
	
	private function thisWidth():Int {
		//if (_ptr == null || Std.is(_ptr, FlxUI) == false) {
			return FlxG.width;
		/*}
		var ptrUI:FlxUI = cast _ptr;
		return Std.int(ptrUI.width);*/
	}
	
	private function thisHeight():Int {
		//if (_ptr == null || Std.is(_ptr, FlxUI) == false) {
			return FlxG.height;
		/*}
		var ptrUI:FlxUI = cast _ptr;
		return Std.int(ptrUI.height);*/
	}
		
	private function _getAnchorPos(thing:IFlxUIWidget, axis:String, str:String):Float
	{
		switch(str)
		{
			case "": return 0;
			case "left": return 0;
			case "right": return screenWidth();
			case "center":
						 if (axis == "x") { return screenWidth() / 2; }
					else if (axis == "y") { return screenHeight() / 2; }
			case "top", "up": return 0;
			case "bottom", "down": return screenHeight();
			default:
				var perc:Float = U.perc_to_float(str);
				if (!Math.isNaN(perc)) {			//it's a percentage
					if (axis == "x") {
						return perc * screenWidth();
					}else if (axis == "y") {
						return perc * screenHeight();
					}
				}else {
					if (U.isFormula(str)) {
						var wh:String = "";
						if (axis == "x") { wh = "w"; }
						if (axis == "y") { wh = "h"; }
						var assetValue:Float = _getStretch(1, wh, str);
						return assetValue;
					}
				}
		}
		return 0;
	}
	
	private function getRound(node:Fast, defaultStr:String = ""):Rounding
	{
		var roundStr:String = U.xml_str(node.x, "round", true, defaultStr);
		switch(roundStr)
		{
			case "floor", "-1", "down": 
				return Rounding.Floor;
			case "up", "1", "ceil", "ceiling": 
				return Rounding.Ceil;
			case "round", "0", "true": 
				return Rounding.Round;
		}
		return Rounding.None;
	}
	
	private function doRound(f:Float, round:Rounding):Float
	{
		switch(round)
		{
			case Rounding.None: return f;
			case Rounding.Floor: return cast Math.floor(f);
			case Rounding.Round: return cast Math.round(f);
			case Rounding.Ceil: return cast Math.ceil(f);
		}
		return f;
	}
	
	private function calcMaxMinSize(data:Fast, width:Null<Float> = null, height:Null<Float> = null):MaxMinSize
	{
		var min_w:Float = 0;
		var min_h:Float = 0;
		var max_w:Float = Math.POSITIVE_INFINITY;
		var max_h:Float = Math.POSITIVE_INFINITY;
		var temp_min_w:Float = 0;
		var temp_min_h:Float = 0;
		var temp_max_w:Float = Math.POSITIVE_INFINITY;
		var temp_max_h:Float = Math.POSITIVE_INFINITY;
		
		var round:Rounding = Rounding.None;
		
		if (data.hasNode.exact_size)
		{
			for (exactNode in data.nodes.exact_size)
			{
				var exact_w_str:String = U.xml_str(exactNode.x, "width");
				var exact_h_str:String = U.xml_str(exactNode.x, "height");
				
				round = getRound(exactNode);
				min_w = doRound(_getDataSize("w", exact_w_str, 0),round);
				min_h = doRound(_getDataSize("h", exact_h_str, 0),round);
				max_w = doRound(min_w,round);
				max_h = doRound(min_h,round);
			}
		}
		else if (data.hasNode.min_size)
		{
			for (minNode in data.nodes.min_size)
			{
				var min_w_str:String = U.xml_str(minNode.x, "width");
				var min_h_str:String = U.xml_str(minNode.x, "height");
				round = getRound(minNode);
				temp_min_w = doRound(_getDataSize("w", min_w_str, 0),round);
				temp_min_h = doRound(_getDataSize("h", min_h_str, 0),round);
				if (temp_min_w > min_w)
				{
					min_w = temp_min_w;
				}
				if (temp_min_h > min_h)
				{
					min_h = temp_min_h;
				}
			}
		}
		else if (data.hasNode.max_size)
		{
			for (maxNode in data.nodes.max_size)
			{
				var max_w_str:String = U.xml_str(maxNode.x, "width");
				var max_h_str:String = U.xml_str(maxNode.x, "height");
				round = getRound(maxNode);
				temp_max_w = doRound(_getDataSize("w", max_w_str, Math.POSITIVE_INFINITY),round);
				temp_max_h = doRound(_getDataSize("h", max_h_str, Math.POSITIVE_INFINITY),round);
				if (temp_max_w < max_w)
				{
					max_w = temp_max_w;
				}
				if (temp_max_h < max_h)
				{
					max_h = temp_max_h;
				}
			}
		}
		else
		{
			return null;
		}
		
		if (width != null)
		{
			if (width > min_w) { min_w = width; }
			if (width < max_w) { max_w = width; }
		}
		if (height != null)
		{
			if (height > min_h) { min_h = height; }
			if (height < max_h) { max_h = height; }
		}
		
		//don't go below 0 folks:
		
		if (max_w <= 0) { max_w = Math.POSITIVE_INFINITY; }
		if (max_h <= 0) { max_h = Math.POSITIVE_INFINITY; }
		
		return { min_width:min_w, min_height:min_h, max_width:max_w, max_height:max_h };
	}
	
	private function _getDataSize(target:String, str:String, default_:Float = 0):Float
	{
		if (U.isStrNum(str))								//Most likely: is it just a number?
		{
			return Std.parseFloat(str);						//If so, parse and return
		}
		var percf:Float = U.perc_to_float(str);				//Next likely: is it a %?
		if (!Math.isNaN(percf))
		{
			switch(target)
			{
				case "w", "width":	return screenWidth() * percf;		//return % of screen size
				case "h", "height": return screenHeight() * percf;
				case "scale", "scale_x", "scale_y": return percf;	//return % as a float
			}
		}
		else
		{
			var chop = U.cheapStringChop(str, "stretch:");
			
			if (chop != str)			//Next likely: is it a stretch command?
			{
				str = chop;
				
				var arr:Array<String> = U.cheap2Split(str,",");
				var stretch_0:Float = _getStretch(0, target, arr[0]);
				var stretch_1:Float = _getStretch(1, target, arr[1]);
				if (stretch_0 != -1 && stretch_1 != -1)
				{
					return stretch_1 - stretch_0;
				}
				else
				{
					return default_;
				}
			}
			else
			{
				chop = U.cheapStringChop(str, "asset:");
				
				if (chop != str)			//Next likely: is it an asset property?
				{
					str = chop;
					var assetValue:Float = _getStretch(1, target, str);
					return assetValue;
				}
				else
				{
					if (U.isFormula(str))	//Next: is it a formula?
					{
						var assetValue:Float = _getStretch(1, target, str);
						return assetValue;
					}
				}
			}
			
			var ptStr:String = "";
			
			if (str.indexOf("pt") == str.length - 2)	//Next likely: is it a pt value?
			{
				ptStr = str.substr(0, str.length - 2);	//chop off the "pt"
			}
			
			if(ptStr != "" && U.isStrNum(ptStr))			//If the rest of it is a simple number
			{
				var tempNum = Std.parseFloat(ptStr);		//process as a variable point value
				
				switch(target)
				{
					case "w", "width": return _pointX * tempNum;
					case "h", "height": return _pointY * tempNum;
				}
			}
		}
		return default_;
	}
	
	/**
	 * Give me a string like "thing.right+10" and I'll return ["+",10]
	 * Only accepts one operator and operand at max!
	 * The operand may be a numer of an asset property.
	 * @param	string of format: <value><operator><operand>
	 * @return [<value>:String,<operator>:String,<operand>:Float]
	 */
	
	private function _getOperation(str:String):Operation
	{
		var list:Array<String> = ["+", "-", "*", "/", "^"];
		var temp:Array<String> = null;
		
		var operator:String = "";
		var besti:Float = Math.POSITIVE_INFINITY;
		
		for (op in list)
		{
			var i = str.indexOf(op);
			if (i != -1)
			{
				if (i < besti)
				{
					besti = i;
					operator = op;
				}
			}
		}
		
		var hasPoint:Bool = false;
		
		if (operator != "")
		{
			if (str.indexOf(operator) != -1)		//return on the FIRST valid operator match found
			{
				var opindex = str.indexOf(operator);
				
				if (opindex != str.length - 1)
				{
					var firstBit:String = str.substr(0, opindex);
					var secondBit:String = str.substr(opindex + 1, str.length - (opindex+1));
					
					var f:Float = 0;
					
					//Check for "pt" syntax and handle it properly
					var ptIndex = secondBit.indexOf("pt");
					if (ptIndex != -1 && ptIndex == secondBit.length - 2)
					{
						var sansPt = U.cheapStringChop(secondBit, "pt");
						f = Std.parseFloat(sansPt);
						hasPoint = true;
					}
					else
					{
						f = Std.parseFloat(secondBit);
					}
					
					if (Math.isNaN(f))
					{
						f = getAssetProperty(1,"",secondBit);
					}
					if (f == 0 && secondBit != "0")
					{
						return null;					//improperly formatted, invalid operand, bail out
					}
					else
					{
						return new Operation(firstBit, Operation.getOperatorTypeFromString(operator), f, hasPoint); //proper operand and operator
					}
				}
			}
		}
		
		return null;
	}
	
	private function _doOperation(value:Float, operator:OperatorType, operand:Float):Float
	{
		switch(operator)
		{
			case OperatorType.Plus: return value + operand;
			case OperatorType.Minus: return value - operand;
			case OperatorType.Divide: return value / operand;
			case OperatorType.Multiply: return value * operand;
			case OperatorType.Exponent: return Math.pow(value, operand);
			default: //donothing
		}
		return value;
	}
	
	private function _getStretch(index:Int, target:String, str:String):Float
	{
		var operator:OperatorType = OperatorType.Plus;
		var operand:Float = 0;
		var hasPoint = false;
		
		var operation:Operation = _getOperation(str);
		
		if (operation != null)
		{
			str = operation.object;
			operator = operation.operator;
			operand = operation.operand;
			hasPoint = operation.hasPoint;
			
			if (hasPoint) {
				switch(target) {
					case "width", "w":
						operand *= _pointX;
					case "height", "h":
						operand *= _pointY;
					default:
						operand *= _pointY;
				}
			}
		}
		
		var return_val:Float = getAssetProperty(index, target, str);
		
		if (return_val != -1 && operator != OperatorType.Unknown)
		{
			return_val = _doOperation(return_val, operator, operand);
		}
		
		return return_val;
	}
	
	private function getAssetProperty(index:Int, target:String, str:String):Float
	{
		var prop:String = "";
		
		var dotI = str.indexOf(".");
		if (dotI != -1)
		{
			var l = str.length;
			prop = str.substr(dotI+1,l-(dotI+1));
			str = str.substr(0,dotI);
		}
		
		var other:IFlxUIWidget = getAsset(str);
		
		var return_val:Float = 0;
		
		if (other == null)
		{
			switch(str)
			{
				case "top", "up": return_val = 0;
				case "bottom", "down": return_val = screenHeight();
				case "left": return_val = 0;
				case "right": return_val = screenWidth();
				default:
					if (U.isStrNum(str))
					{
						return_val = Std.parseFloat(str);
					}
					else
					{
						return_val = -1;
					}
			}
		}
		else
		{
			switch(target)
			{
				case "w", "width": 
					if (prop == "")
					{
						if (index == 0) { return_val = other.x + other.width; }
						if (index == 1) { return_val = other.x; }
					}
					else
					{
						switch(prop)
						{
							case "top", "up", "y": return_val = other.y;
							case "bottom", "down": return_val = other.y +other.height;
							case "right": return_val = other.x + other.width;
							case "left","x": return_val = other.x;
							case "center": return_val = other.x + (other.width / 2);
							case "width": return_val = other.width;
							case "height": return_val = other.height;
							case "halfheight": return_val = other.height / 2;
							case "halfwidth": return_val = other.width / 2;
						}
					}
				case "h", "height":
					if (prop == "")
					{
						if (index == 0) { return_val = other.y + other.height; }
						if (index == 1) { return_val = other.y; }
					}
					else
					{
						switch(prop){
							case "top", "up", "y": return_val = other.y;
							case "bottom", "down": return_val = other.y +other.height;
							case "right": return_val = other.x + other.width;
							case "left","x": return_val = other.x;
							case "center": return_val = other.y + (other.height / 2);
							case "height": return_val = other.height;
							case "width": return_val = other.width;
							case "halfheight": return_val = other.height / 2;
							case "halfwidth": return_val = other.width / 2;
						}
					}
				default:
					switch(prop)
					{
						case "top", "up", "y": return_val = other.y;
						case "bottom", "down": return_val = other.y +other.height;
						case "right": return_val = other.x + other.width;
						case "left","x": return_val = other.x;
						case "centery": return_val = other.y + (other.height / 2);
						case "centerx": return_val = other.x + (other.width / 2);
						case "height": return_val = other.height;
						case "width": return_val = other.width;
						case "halfheight": return_val = other.height / 2;
						case "halfwidth": return_val = other.width / 2;
					}
			}
		}
		return return_val;
	}
	
	private function _loadCursor(data:Fast):Void
	{
		if (data.hasNode.list)
		{
			if (cursorLists == null)
			{
				cursorLists = [];
			}
			for (lNode in data.nodes.list)
			{
				var ids:String = U.xml_str(lNode.x, "ids");
				var arr = ids.split(",");
				if (arr != null && arr.length > 0)
				{
					var list:Array<IFlxUIWidget> = [];
					for (str in arr)
					{
						var widget = getAsset(str);
						if (widget != null)
						{
							list.push(widget);
						}
					}
					cursorLists.push(list);
				}
			}
		}
	}
	
	private function _loadPosition(data:Fast, thing:IFlxUIWidget):Void
	{
		if (thing == null) return;
		
		var X:Float = _loadX(data);			//position offset from 0,0
		var Y:Float = _loadY(data);
		
		var name = U.xml_name(data.x);
		
		//if you don't define x or y in an anchor, they default to 0
		//but if you set x="same" / y="same", you default to whatever it was before
		
		var ctrX:Bool = U.xml_bool(data.x, "center_x");	//if true, centers on the screen
		var ctrY:Bool = U.xml_bool(data.x, "center_y");
		
		var center_on:String = U.xml_str(data.x, "center_on");
		var center_on_x:String = U.xml_str(data.x, "center_on_x");
		var center_on_y:String = U.xml_str(data.x, "center_on_y");
		
		var anchor_x_str:String = "";
		var anchor_y_str:String = "";
		var anchor_x:Float = 0;
		var anchor_y:Float = 0;
		var anchor_x_flush:String = "";
		var anchor_y_flush:String = "";
		
		if (data.hasNode.anchor)
		{
			anchor_x_str = U.xml_str(data.node.anchor.x, "x");
			anchor_y_str = U.xml_str(data.node.anchor.x, "y");
			
			var rounding:Rounding = getRound(data.node.anchor);
			
			anchor_x = _getAnchorPos(thing, "x", anchor_x_str);
			anchor_y = _getAnchorPos(thing, "y", anchor_y_str);
			
			anchor_x = doRound(anchor_x, rounding);
			anchor_y = doRound(anchor_y, rounding);
			
			anchor_x_flush = U.xml_str(data.node.anchor.x, "x-flush",true);
			anchor_y_flush = U.xml_str(data.node.anchor.x, "y-flush", true);
		}
		
		//Flush it to the anchored coordinate
		if (anchor_x_str != "" || anchor_y_str != "")
		{
			switch(anchor_x_flush)
			{
				case "left":	//do-nothing		 					//flush left side to anchor
				case "right":	anchor_x = anchor_x - thing.width;	 	//flush right side to anchor
				case "center":  anchor_x = anchor_x - thing.width / 2;	//center on anchor point
			}
			switch(anchor_y_flush)
			{
				case "up", "top": //do-nothing
				case "down", "bottom": anchor_y = anchor_y - thing.height;
				case "center": anchor_y = anchor_y - thing.height / 2;
			}
			
			if (anchor_x_str != "")
			{
				thing.x = anchor_x;
			}
			if (anchor_y_str != "")
			{
				thing.y = anchor_y;
			}
			
		}
		
		//Try to center the object on the screen:
		if (ctrX || ctrY) {
			_center(thing,ctrX,ctrY);
		}
		
		//Then, try to center it on another object:
		if (center_on != "")
		{
			var other = getAsset(center_on);
			if (other != null)
			{
				U.center(cast(other, FlxObject), cast(thing, FlxObject));
			}
		}
		else
		{
			if (center_on_x != "")
			{
				var other = getAsset(center_on_x);
				if (other != null)
				{
					U.center(cast(other, FlxObject), cast(thing, FlxObject), true, false);
				}
			}
			if (center_on_y != "")
			{
				var other = getAsset(center_on_y);
				if (other != null)
				{
					U.center(cast(other, FlxObject), cast(thing, FlxObject), false, true);
				}
			}
		}
		
		//Then, add its offset to wherever it wound up:
		_delta(thing, X, Y);
	}
	
	private function _loadBorder(data:Fast):BorderDef
	{
		var borderDef = BorderDef.fromXML(data.x);
		
		var round:Rounding = getRound(data, "floor");
		var dataSize = _getDataSize("h", U.xml_str(data.x, "border_size") , 1);
		var border_size:Int = Std.int(doRound(dataSize, round));
		
		borderDef.size = border_size;
		
		return borderDef;
	}
	
	private function _loadColor(data:Fast,colorName:String="color",_default:Int=0xffffffff):Int {
		var colorStr:String = U.xml_str(data.x, colorName);
		if (colorStr == "" && data.x.nodeName == colorName) { 
			colorStr = U.xml_str(data.x, "value"); 
		}
		var color:Int = _default;
		if (colorStr != "") { color = U.parseHex(colorStr, true); }
		return color;
	}
	
	private function _loadFontDef(data:Fast):FontDef {
		var fd:FontDef = FontDef.fromXML(data.x);
		var fontSize:Int = Std.int(_loadHeight(data, 8, "size"));
		fd.format.size = FlxUI.fontSize(fd.file,fontSize);
		fd.size = fontSize;
		return fd;
	}
	
	private function _loadFontFace(data:Fast):String{
		var fontFace:String = U.xml_str(data.x, "font"); 
		var fontStyle:String = U.xml_str(data.x, "style");
		var the_font:String = null;
		if (fontFace != "") { the_font = FlxUI.font(fontFace, fontStyle); }
		return the_font;
	}
	
	private function _onFinishLoad():Void
	{
		if (_ptr != null)
		{
			_ptr.getEvent("finish_load", this, null);
		}
	}
	
	/**********UTILITY FUNCTIONS************/
	
	public function getText(flag:String, context:String = "data", safe:Bool = true, code:String=""):String {
		var str:String = "";
		if(_ptr_tongue != null){
			str = _ptr_tongue.get(flag, context, safe);
			return formatFromCode(str, code);
		}else if(getTextFallback != null){
			str = getTextFallback(flag, context, safe);
			return formatFromCode(str, code);
		}
		
		return flag;
	}
	
	private function formatFromCode(str:String, code:String):String {
		
		if (formatFromCodeCallback != null)
		{
			return formatFromCodeCallback(str, code);
		}
		
		switch(code) {
			case "u": return str.toUpperCase();		//uppercase
			case "l": return str.toLowerCase();		//lowercase
			case "fu": return U.FU(str);			//first letter uppercase
			case "fu_": return U.FU_(str);			//first letter in each word uppercase
		}
		return str;
	}
	
	
	/**
	 * Parses params out of xml and loads them in the correct type
	 * @param	data
	 */
	
	private static inline function getParams(data:Fast):Array<Dynamic>{
		var params:Array<Dynamic> = null;
		
		if (data.hasNode.param) {
			params = new Array<Dynamic>();
			for (param in data.nodes.param) {
				if(param.has.type && param.has.value){
					var type:String = param.att.type;
					type = type.toLowerCase();
					var valueStr:String = param.att.value;
					var value:Dynamic = valueStr;
					var sort:Int = U.xml_i(param.x, "sort",-1);
					switch(type) {
						case "string": value = new String(valueStr);
						case "int": value = Std.parseInt(valueStr);
						case "float": value = Std.parseFloat(valueStr);
						case "color", "hex": value = U.parseHex(valueStr, true);
						case "bool", "boolean": 
							var str:String = new String(valueStr);
							str = str.toLowerCase();
							if (str == "true" || str == "1") {
								value = true;
							}else{
								value = false;
							}
					}
					
					//Add sorting metadata to the array
					params.push( { sort:sort, value:value } );
				}
			}
			
			//Sort the array
			params.sort(sortParams);
			
			//Strip out the sorting metdata
			for (i in 0...params.length) {
				params[i] = params[i].value;
			}
		}
		return params;
	}
	
	private static function sortParams(a:SortValue, b:SortValue):Int
	{
		if (a.sort < b.sort) return -1;
		if (a.sort > b.sort) return 1;
		return 0;
	}
	
	private function getUseDef(node:Fast, attName:String="use_def")
	{
		var use_def:String = U.xml_str(node.x, attName, true);
		
		if (node.hasNode.resolve(attName))
		{
			if(_loadTest(node, attName))
			{
				use_def = U.xml_str(node.node.resolve(attName).x, "definition");
			}
		}
		
		var theDef:Fast = null;
		if (use_def != "")
		{
			theDef = getDefinition(use_def);
		}
		
		return theDef;
	}
	
	private function formatButtonText(data:Fast, button:Dynamic):FlxText
	{
		if (data != null && data.hasNode.text)
		{
			var textNode = data.node.text;
			
			var text_def:Fast = getUseDef(textNode);
			var info:Fast = consolidateData(textNode, text_def);
			
			var case_name:String = U.xml_name(info.x);
			var the_font:String = _loadFontFace(info);
			var size:Int = Std.int(_loadHeight(info, 8, "size", "floor"));
			var color:Int = _loadColor(info);
			
			var labelWidth:Float = U.xml_f(info.x, "width");
			
			var border:BorderDef = _loadBorder(info);
			
			var align:String = U.xml_str(info.x, "align", true); if (align == "") { align = null;}
			
			var leadingExists = U.xml_str(info.x, "leading", true, "");
			var leadingInt:Null<Int> = Std.int(_loadHeight(info, 0, "leading", "floor"));
			
			leadingInt = leadingExists != "" ? leadingInt : null;
			
			var the_label:FlxText=null;
			var fb:FlxUIButton = null;
			var fsb:FlxUISpriteButton = null;
			var cb:FlxUICheckBox = null;
			var ifb:IFlxUIButton = null;
			
			if (Std.is(button, FlxUICheckBox) == false)
			{
				ifb = cast button;
				if (align == "" || align == null)
				{
					align = "center";
				}
			}
			else
			{
				var cb:FlxUICheckBox = cast button;
				ifb = cb.button;
				align = "left";			//force this for check boxes
			}
			
			if (ifb != null)
			{
				if (Std.is(ifb, FlxUIButton)) 
				{
					fb = cast ifb;
					the_label = fb.label;
				}
				else if (Std.is(ifb, FlxUISpriteButton))
				{
					fsb = cast ifb;
					if (Std.is(fsb.label, FlxText)) 				//if label is text, just grab it
					{
						the_label = cast fsb.label;
					}
					else if (Std.is(fsb.label, FlxSpriteGroup))		//if label is group, look for first flxtext label
					{
						var fsg:FlxSpriteGroup = cast fsb.label;
						for (fs in fsg.group.members) {
							if (Std.is(fs, FlxText)) {
								the_label = cast fs;				//grab it!
								break;
							}
						}
					}
				}
				
				ifb.up_color = color;
				ifb.down_color = 0;
				ifb.over_color = 0;
			}
			
			if (the_label != null)
			{
				if (labelWidth != 0)
				{
					the_label.width = labelWidth;
					the_label.resetHelpers();
				}
				
				if (fb != null)
				{
					fb.setLabelFormat(the_font, size, color, align);
				}
				else
				{
					the_label.setFormat(the_font, size, color, align);
				}
				
				var dtf = the_label.textField.defaultTextFormat;
				dtf.leading = leadingInt;
				
				the_label.textField.defaultTextFormat = dtf;
				
				the_label.borderStyle = border.style;
				the_label.borderColor = border.color;
				the_label.borderSize = border.size;
				the_label.borderQuality = border.quality;
				
				if (Std.is(the_label, FlxUIText))
				{
					var ftu:FlxUIText = cast the_label;
					ftu.drawFrame();
				}
				
				if (fb != null)
				{
					fb.centerLabel();
				}
				if (fsb != null)
				{
					fsb.centerLabel();
				}
			}
			
			for (textColorNode in info.nodes.color)
			{
				var color:Int = _loadColor(textColorNode);
				var vis:Bool = U.xml_bool(textColorNode.x, "visible", true);
				var state_name:String = U.xml_name(textColorNode.x);
				var toggle:Bool = U.xml_bool(textColorNode.x, "toggle");
				switch(state_name)
				{
					case "up", "inactive", "", "normal": 
						if (!toggle)
						{
							ifb.up_color = color; 
							ifb.up_visible = vis;
						}
						else
						{
							ifb.up_toggle_color = color;
							ifb.up_toggle_visible = vis;
						}
					case "active", "hilight", "over", "hover": 
						if (!toggle)
						{
							ifb.over_color = color; 
							ifb.over_visible = vis;
						}
						else
						{
							ifb.over_toggle_color = color;
							ifb.over_toggle_visible = vis;
						}
					case "down", "pressed", "pushed": 
						if (!toggle)
						{
							ifb.down_color = color; 
							ifb.down_visible = vis;
						}
						else
						{
							ifb.down_toggle_color = color;
							ifb.down_toggle_visible = vis;
						}
				}
			}
			
			if (ifb.over_color == 0)			//if no over color, match up color
			{
				ifb.over_color = ifb.up_color;
			}
			if (ifb.down_color == 0)			//if no down color, match over color
			{
				ifb.down_color = ifb.over_color;
			}
			
			//if toggles are undefined, match them to the normal versions
			if (ifb.up_toggle_color == 0)
			{
				ifb.up_toggle_color = ifb.up_color;
			}
			if (ifb.over_toggle_color == 0)
			{
				ifb.over_toggle_color = ifb.over_color;
			}
			if (ifb.down_toggle_color == 0)
			{
				ifb.down_toggle_color = ifb.down_color;
			}
			
			if (the_label != null) {
				the_label.visible = ifb.up_visible;
				the_label.color = ifb.up_color;
			}
			return the_label;
		}
		return null;
	}
}

typedef UIEventCallback = String->IFlxUIWidget->Dynamic->Array<Dynamic>->Void;

enum Rounding{
	Floor;
	Ceil;
	Round;
	None;
}

typedef SortValue = {
	var sort:Int;
	var value:Dynamic;
}

typedef NamedBool = {
	name:String,
	value:Bool
}

typedef NamedInt = {
	name:String,
	value:Int
}

typedef NamedFloat = {
	name:String,
	value:Float
}

typedef NamedString = {
	name:String,
	value:String
}

typedef MaxMinSize = {
	min_width:Float,
	min_height:Float,
	max_width:Float,
	max_height:Float
}

typedef VarValue = {
	variable:String,
	value:String,
	operator:String
}

@:noCompletion
class Operation 
{
	public var object:String;
	public var operator:OperatorType;
	public var operand:Float;
	public var hasPoint:Bool;
	
	public function new(Object:String, Operator:OperatorType, Operand:Float, HasPoint:Bool)
	{
		object = Object;
		operator = Operator;
		operand = Operand;
		hasPoint = HasPoint;
	}
	
	public static function getOperatorTypeFromString(str:String):OperatorType
	{
		switch(str)
		{
			case "+": return OperatorType.Plus;
			case "-": return OperatorType.Minus;
			case "*": return OperatorType.Multiply;
			case "/": return OperatorType.Divide;
			case "^": return OperatorType.Exponent;
			default: return OperatorType.Unknown;
		}
		return OperatorType.Unknown;
	}
}

@:noCompletion
@:enum
abstract OperatorType(Int) {
  var Plus = 0;
  var Minus = 1;
  var Multiply = 2;
  var Divide = 3;
  var Exponent = 4;
  var Unknown = 5;
}

//"+", "-", "*", "/", "^"