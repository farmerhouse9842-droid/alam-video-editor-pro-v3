import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:video_player/video_player.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:path/path.dart' as p;
import 'package:file_picker/file_picker.dart';

void main() => runApp(const AlamApp());
const gold = Color(0xFFFFBF4A);
const bg = Color(0xFF090B10);
class AlamApp extends StatelessWidget {
  const AlamApp({super.key});
  @override Widget build(BuildContext context) => MaterialApp(
    debugShowCheckedModeBanner: false,
    title: 'Alam Video Editor Pro',
    theme: ThemeData.dark().copyWith(scaffoldBackgroundColor:bg, colorScheme: const ColorScheme.dark(primary:gold, secondary:gold, surface:Color(0xFF171A22))),
    home: const EditorHome());
}
class EditorHome extends StatefulWidget {const EditorHome({super.key}); @override State<EditorHome> createState()=>_EditorHomeState();}
class _EditorHomeState extends State<EditorHome> {
  static const channel=MethodChannel('alam.video.editor/trim');
  VideoPlayerController? controller;
  String? source, exported;
  final List<String> splitOutputs=[];
  double start=0,end=1;
  bool busy=false;
  final List<String> clips=[];
  String? selectedMusic;
  String overlayText='';
  double overlaySize=26;
  double brightness=0;
  bool replaceAudio=false;
  String status='একটি ভিডিও নির্বাচন করুন';
  Duration get duration => controller?.value.duration ?? Duration.zero;
  String fmt(double sec){final d=Duration(milliseconds:(sec*1000).round()); return '${d.inMinutes.remainder(60).toString().padLeft(2,'0')}:${d.inSeconds.remainder(60).toString().padLeft(2,'0')}';}
  Future<void> pick() async {
    try {
      final file=await ImagePicker().pickVideo(source:ImageSource.gallery);
      if(file==null)return;
      final next=VideoPlayerController.file(File(file.path));
      await next.initialize();
      await controller?.dispose();
      next.addListener(()=>{if(mounted) setState((){})});
      setState((){controller=next; source=file.path; clips.clear(); clips.add(file.path); exported=null; splitOutputs.clear(); start=0; end=next.value.duration.inMilliseconds/1000.0; status='Trim-এর সময় নির্বাচন করুন';});
    }catch(e){setState(()=>status='ভিডিও খোলা যায়নি: $e');}
  }
   Future<void> addClip() async {
     if(busy)return;
     try {
       final file=await ImagePicker().pickVideo(source:ImageSource.gallery);
       if(file==null)return;
       setState(() { clips.add(file.path); status='${clips.length} ভিডিও নির্বাচন করা হয়েছে'; });
     } catch(e) { if(mounted)setState(()=>status='ভিডিও যোগ করা যায়নি: $e'); }
   }
   Future<void> chooseMusic() async {
     try {
       final r=await FilePicker.platform.pickFiles(type:FileType.audio);
       if(r==null || r.files.single.path==null)return;
       setState(() {selectedMusic=r.files.single.path;status='Music নির্বাচিত। Replace audio চালু করলে MP4 Export-এ AAC গান ব্যবহার হবে।';});
     }catch(e){if(mounted)setState(()=>status='Music নির্বাচন ব্যর্থ: $e');}
   }
   Future<void> editText() async {
    final textController=TextEditingController(text:overlayText);
    final chosen=await showDialog<String>(context:context,builder:(ctx)=>AlertDialog(
      title:const Text('Text overlay (preview only)'),
      content:TextField(controller:textController,maxLines:3,decoration:const InputDecoration(hintText:'বাংলা / English text')),
      actions:[TextButton(onPressed:()=>Navigator.pop(ctx),child:const Text('Cancel')),
        TextButton(onPressed:()=>Navigator.pop(ctx,textController.text),child:const Text('Apply'))]));
    if(chosen!=null && mounted)setState(()=>overlayText=chosen);
    textController.dispose();
  }
  Future<void> exportWithMusic() async {
    if(source==null || selectedMusic==null || busy)return;
    setState(() {busy=true;status='ভিডিওতে নতুন Audio যোগ হচ্ছে...';});
    try {
      await controller?.pause();
      final dir=await getApplicationDocumentsDirectory();
      final out=p.join(dir.path,'alam_music_${DateTime.now().millisecondsSinceEpoch}.mp4');
      final result=await channel.invokeMethod<String>('replaceAudio',{
        'input':source,'music':selectedMusic,'output':out,
        'startMs':(start*1000).round(),'endMs':(end*1000).round()});
      if(result==null || !File(result).existsSync())throw Exception('No exported file');
      if(mounted)setState(() {exported=result;splitOutputs.clear();status='Music-সহ MP4 Export হয়েছে। Share / Save করুন।';});
    }catch(e){if(mounted)setState(()=>status='Music Export ব্যর্থ: $e. AAC audio ব্যবহার করুন।');}
    finally{if(mounted)setState(()=>busy=false);}
  }
  Future<void> splitVideo() async {
     if(source==null || busy || end-start<0.5)return;
     final midpoint=(start+end)/2;
     setState(() {busy=true;status='ভিডিও দুই ভাগে Export হচ্ছে...';});
     try {
       await controller?.pause();
       final dir=await getApplicationDocumentsDirectory();
       final stamp=DateTime.now().millisecondsSinceEpoch;
       final a=p.join(dir.path,'alam_${stamp}_part1.mp4');
       final b=p.join(dir.path,'alam_${stamp}_part2.mp4');
       for(final item in [(a,start,midpoint),(b,midpoint,end)]) {
         final out=await channel.invokeMethod<String>('trim',{'input':source,'output':item.$1,'startMs':(item.$2*1000).round(),'endMs':(item.$3*1000).round()});
         if(out==null || !File(out).existsSync())throw Exception('Split failed');
       }
       if(mounted)setState(() {exported=a;splitOutputs..clear()..addAll([a,b]);status='Split সফল: দুটি MP4 তৈরি হয়েছে। নিচে দুটি অংশ আলাদাভাবে Save করুন।';});
     }catch(e){if(mounted)setState(()=>status='Split ব্যর্থ: $e');}
     finally{if(mounted)setState(()=>busy=false);}
   }
   Future<void> mergeVideos() async {
     if(clips.length<2 || busy)return;
     setState(() {busy=true;status='ভিডিও Merge হচ্ছে...';});
     try {
       await controller?.pause();
       final dir=await getApplicationDocumentsDirectory();
       final out=p.join(dir.path,'alam_merged_${DateTime.now().millisecondsSinceEpoch}.mp4');
       final result=await channel.invokeMethod<String>('merge',{'inputs':clips,'output':out});
       if(result==null || !File(result).existsSync())throw Exception('Merge failed');
       if(mounted)setState(() {exported=result;splitOutputs.clear();status='Merge সফল! Share / Save করুন।';});
     }catch(e){if(mounted)setState(()=>status='Merge ব্যর্থ: $e. একই resolution ও codec-এর ভিডিও ব্যবহার করুন।');}
     finally{if(mounted)setState(()=>busy=false);}
   }
  Future<void> export() async {
    if(source==null||busy||end<=start)return;
    setState((){busy=true; status='ভিডিও Export হচ্ছে...';});
    try {
      await controller?.pause();
      final dir=await getApplicationDocumentsDirectory();
      final out=p.join(dir.path,'alam_${DateTime.now().millisecondsSinceEpoch}.mp4');
      final result=await channel.invokeMethod<String>('trim',{'input':source,'output':out,'startMs':(start*1000).round(),'endMs':(end*1000).round()});
      if(result==null||!File(result).existsSync()) throw Exception('Export failed');
      setState((){exported=result;splitOutputs.clear();status='Export সফল! Share করে Gallery বা Files-এ সংরক্ষণ করতে পারবেন।';});
    }catch(e){setState(()=>status='Export ব্যর্থ: $e');}
    finally {if(mounted)setState(()=>busy=false);}
  }
  @override void dispose(){controller?.dispose();super.dispose();}
  Widget panel({required Widget child})=>Container(padding:const EdgeInsets.all(16),decoration:BoxDecoration(color:const Color(0xFF171A22),borderRadius:BorderRadius.circular(20),border:Border.all(color:gold.withValues(alpha:.2))),child:child);
  @override Widget build(BuildContext context){
    final ready=controller?.value.isInitialized??false;
    final max=duration.inMilliseconds/1000.0;
    return Scaffold(appBar:AppBar(backgroundColor:bg,title:const Text('ALAM  •  VIDEO EDITOR PRO',style:TextStyle(fontSize:17,fontWeight:FontWeight.bold,color:gold))),body:SafeArea(child:ListView(padding:const EdgeInsets.all(16),children:[
      panel(child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[const Text('Create your next video',style:TextStyle(fontSize:21,fontWeight:FontWeight.bold)),const SizedBox(height:10),const Text('Offline video editing • Black & Gold',style:TextStyle(color:Colors.white60)),const SizedBox(height:16),SizedBox(width:double.infinity,child:FilledButton.icon(onPressed:busy?null:pick,icon:const Icon(Icons.video_library),label:const Text('নতুন ভিডিও নির্বাচন করুন')))])),
      const SizedBox(height:14),
      panel(child:Column(children:[
        AspectRatio(aspectRatio:ready&&controller!.value.aspectRatio>0?controller!.value.aspectRatio:16/9,child:Container(color:Colors.black,child:ready?Stack(fit:StackFit.expand,children:[ColorFiltered(colorFilter:ColorFilter.matrix(<double>[1,0,0,0,brightness*255,0,1,0,0,brightness*255,0,0,1,0,brightness*255,0,0,0,1,0]),child:VideoPlayer(controller!)),if(overlayText.isNotEmpty)Center(child:Text(overlayText,textAlign:TextAlign.center,style:TextStyle(fontSize:overlaySize,color:gold,fontWeight:FontWeight.bold,shadows:const [Shadow(color:Colors.black,blurRadius:6)]))) ]):const Center(child:Icon(Icons.movie_creation_outlined,size:70,color:Colors.white38)))),
        const SizedBox(height:12),if(ready) ...[
          Row(children:[IconButton(onPressed:(){controller!.value.isPlaying?controller!.pause():controller!.play();setState((){});},icon:Icon(controller!.value.isPlaying?Icons.pause_circle:Icons.play_circle,color:gold,size:38)),Expanded(child:Slider(value:(controller!.value.position.inMilliseconds/1000.0).clamp(0,max),min:0,max:max>0?max:1,onChanged:(v)=>controller!.seekTo(Duration(milliseconds:(v*1000).round())))),Text(fmt(controller!.value.position.inMilliseconds/1000.0))]),
          const Align(alignment:Alignment.centerLeft,child:Text('TIMELINE / TRIM',style:TextStyle(fontWeight:FontWeight.bold,color:gold))),
          RangeSlider(values:RangeValues(start.clamp(0,max),end.clamp(0,max)),min:0,max:max>0?max:1,labels:RangeLabels(fmt(start),fmt(end)),onChanged:(r)=>setState((){start=r.start;end=r.end;})),
          Row(mainAxisAlignment:MainAxisAlignment.spaceBetween,children:[Text('Start: ${fmt(start)}'),Text('End: ${fmt(end)}')]),
        ] else const Padding(padding:EdgeInsets.all(18),child:Text('ভিডিও নির্বাচন করলে এখানে Preview ও Timeline দেখা যাবে।')),
      ])),
      const SizedBox(height:14),panel(child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[
        const Text('V3 EDITING TOOLS',style:TextStyle(color:gold,fontWeight:FontWeight.bold)),
        const SizedBox(height:10),
        Wrap(spacing:8,runSpacing:8,children:[
          OutlinedButton.icon(onPressed:busy?null:addClip,icon:const Icon(Icons.add),label:const Text('Add clip')),
          OutlinedButton.icon(onPressed:ready&&!busy?splitVideo:null,icon:const Icon(Icons.content_cut),label:const Text('Split in half')),
          OutlinedButton.icon(onPressed:clips.length>=2&&!busy?mergeVideos:null,icon:const Icon(Icons.merge),label:const Text('Merge clips')),
          OutlinedButton.icon(onPressed:busy?null:chooseMusic,icon:const Icon(Icons.music_note),label:const Text('Choose music')),
          OutlinedButton.icon(onPressed:busy?null:editText,icon:const Icon(Icons.text_fields),label:const Text('Text preview')),
          OutlinedButton.icon(onPressed:selectedMusic!=null && ready && !busy?exportWithMusic:null,icon:const Icon(Icons.audiotrack),label:const Text('Export with music')),
        ]),
        const SizedBox(height:8),Text('Clips: ${clips.length} • Music: ${selectedMusic==null ? "Not selected" : p.basename(selectedMusic!)}',style:const TextStyle(color:Colors.white70)),
        const SizedBox(height:8),
        const Text('Preview brightness (not applied to MP4 export)',style:TextStyle(color:Colors.white70)),
        Slider(value:brightness,min:-0.5,max:0.5,onChanged:(v)=>setState(()=>brightness=v)),
        if(overlayText.isNotEmpty)Slider(value:overlaySize,min:14,max:54,onChanged:(v)=>setState(()=>overlaySize=v)),
        const Text('Music export REPLACES original sound (AAC only). Text and brightness affect preview only. No audio mixing or text burn-in yet.',style:TextStyle(color:Colors.white54,fontSize:12)),
      ])),
      const SizedBox(height:14),panel(child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[const Text('EXPORT',style:TextStyle(color:gold,fontWeight:FontWeight.bold)),const SizedBox(height:8),const Text('MP4 • Original streams • Keyframe-aligned trim',style:TextStyle(color:Colors.white60,fontSize:12)),const SizedBox(height:14),SizedBox(width:double.infinity,child:FilledButton.icon(onPressed:ready&&!busy&&end>start?export:null,icon:busy?const SizedBox(width:16,height:16,child:CircularProgressIndicator(strokeWidth:2)):const Icon(Icons.file_download),label:Text(busy?'Export হচ্ছে...':'ভিডিও Export করুন'))),if(exported!=null && splitOutputs.isEmpty) SizedBox(width:double.infinity,child:OutlinedButton.icon(onPressed:()=>Share.shareXFiles([XFile(exported!)]),icon:const Icon(Icons.share),label:const Text('Share / Save exported video'))),if(splitOutputs.isNotEmpty) ...[for(var i=0;i<splitOutputs.length;i++) SizedBox(width:double.infinity,child:OutlinedButton.icon(onPressed:()=>Share.shareXFiles([XFile(splitOutputs[i])]),icon:const Icon(Icons.share),label:Text('Save split part ${i+1}')))],const SizedBox(height:10),Text(status,style:const TextStyle(color:Colors.white70))])),
      const SizedBox(height:14),panel(child:const Column(crossAxisAlignment:CrossAxisAlignment.start,children:[Text('COMING NEXT • ONLINE + AI',style:TextStyle(color:gold,fontWeight:FontWeight.bold)),SizedBox(height:8),Text('Templates • AI subtitles • Audio mixing • Text burn-in • Multi-track editing • Transitions',style:TextStyle(color:Colors.white70)),SizedBox(height:8),Text('এগুলো এখনও চালু হয়নি।',style:TextStyle(color:Colors.white54))]))
    ])));
  }
}
