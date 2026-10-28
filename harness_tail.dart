bool _fixtureFeatureEnabled=true;
final _fixtureFiles=<EnteFile>[];
class _FixtureFavorites implements FavoritesService {
 @override bool isFavoriteCache(EnteFile file,{bool checkOnlyAlbum=false}) => file.generatedID==6;
 @override dynamic noSuchMethod(Invocation invocation)=>super.noSuchMethod(invocation);
}
ReviewMonthSummary _summary(int year,int month,int n,int decided,{int queued=0}) => ReviewMonthSummary(key:ReviewMonthKey(year,month),cover:_fixtureFiles[month%_fixtureFiles.length],totalCount:n,decidedCount:decided,queuedCount:queued,markedReviewed:false,lastReviewedAt:month);
ReviewOverview _overviewFixture(String scene) {
 if(scene=='empty') return const ReviewOverview(years:[],bannerMonths:[]);
 final active=[_summary(2026,1,24,0),_summary(2026,2,16,16),_summary(2026,3,36,12,queued:3),_summary(2026,4,28,0),_summary(2026,5,18,18),_summary(2026,6,42,28,queued:5)];
 final complete=[_summary(2025,1,18,18),_summary(2025,7,24,24),_summary(2025,12,32,32)];
 return ReviewOverview(years:[if(!scene.endsWith('year')) ReviewYearSummary(year:2026,months:active),ReviewYearSummary(year:2025,months:complete)],bannerMonths:scene.endsWith('year')?[]:[active.last,active[3]]);
}
class _FixtureOverview extends ReviewOldPhotosPage {
 const _FixtureOverview(this.scene);
 final String scene;
 @override State<ReviewOldPhotosPage> createState()=>_FixtureOverviewState(scene);
}
class _FixtureOverviewState extends _ReviewOldPhotosPageState {
 _FixtureOverviewState(this.scene); final String scene;
 @override Future<void> _load() async {}
 @override void initState(){super.initState();_overview=_overviewFixture(scene);if(scene=='expanded-year')_expandedYears.add(2025);if(scene=='selection') _selected.addAll([const ReviewMonthKey(2026,1),const ReviewMonthKey(2026,3)]);}
}
class _FixtureMonth extends ReviewMonthPage {
 const _FixtureMonth(this.scene):super(monthKey:const ReviewMonthKey(2026,6));
 final String scene;
 @override State<ReviewMonthPage> createState()=>_FixtureMonthState(scene);
}
class _FixtureMonthState extends _ReviewMonthPageState {
 _FixtureMonthState(this.scene); final String scene;
 @override Future<void> _load({bool resetView=true}) async {}
 @override void _write(String action,Future<void> Function() operation) {}
 @override void initState(){super.initState();_loaded=true;_files=List.of(_fixtureFiles);
 for(final f in _files.take(3)){_decisions[PhotoReviewService.fileKey(f)]=ReviewDecision.queued;}
 for(final f in _files.skip(3).take(2)){_decisions[PhotoReviewService.fileKey(f)]=ReviewDecision.keep;}
 _rebuildUndecided();
 _history.add((_files[4],ReviewSwipeDirection.right));
 if(scene=='video'){_undecided.remove(_files.last);_undecided.insert(0,_files.last);}
 if(scene=='queue'||scene=='confirmation')_view=_ReviewMonthView.queue;
 if(scene.startsWith('done')){_view=_ReviewMonthView.done;_record=ReviewMonthRecord(monthKey:'2026-06',markedReviewed:false,freedBytes:scene=='done-freed'?134217728:0,freedCount:scene=='done-freed'?12:0,updatedAt:1);}
 }
}
void main(){
 TestWidgetsFlutterBinding.ensureInitialized();
 setUpAll(() async {
  SharedPreferences.setMockInitialValues({});
  ServiceLocator.instance.localSettings=LocalSettings(await SharedPreferences.getInstance());
  FavoritesService.instance=_FixtureFavorites();
  for(final family in ['Inter','Outfit']){final loader=FontLoader('packages/ente_components/$family');for(final weight in ['Regular','Medium','SemiBold','Bold']){loader.addFont(rootBundle.load('packages/ente_components/fonts/$family-$weight.ttf'));}await loader.load();}
  for(final font in {'MaterialIcons':'fonts/MaterialIcons-Regular.otf','packages/ente_icons/EnteIcons':'packages/ente_icons/fonts/EnteIcons.ttf'}.entries){final loader=FontLoader(font.key)..addFont(rootBundle.load(font.value));await loader.load();}
  final source=File('${Directory.current.parent.parent.parent.path}/infra/ml/playground/data/singapore.jpg').readAsBytesSync();
  for(var i=0;i<12;i++){
   final file=EnteFile()..uploadedFileID=100+i..generatedID=i+1..creationTime=DateTime(2026,6,i+1).microsecondsSinceEpoch..title='Sample ${i+1}'..fileType=(i==11?FileType.video:FileType.image)..fileSize=11862016..duration=(i==11?82:null);
   _fixtureFiles.add(file);ThumbnailInMemoryLruCache.put(file,source,thumbnailLargeSize);ThumbnailInMemoryLruCache.put(file,source,thumbnailSmallSize);
  }
 });
 for(final dark in [false,true]){for(final scene in ['entry','overview','selection','completed-year','expanded-year','swipe','keep-swipe','delete-swipe','video','queue','confirmation','done-freed','done-kept','empty']){
 testWidgets('$scene ${dark?'dark':'light'}',(tester) async{
  debugDisableShadows=false;
  addTearDown((){debugDisableShadows=true;});
  tester.view.physicalSize=const Size(393,852);tester.view.devicePixelRatio=1;
  addTearDown(tester.view.resetPhysicalSize);addTearDown(tester.view.resetDevicePixelRatio);
  _fixtureFeatureEnabled=scene!='entry-before';
  final Widget page=scene.startsWith('entry')?const FreeUpSpaceOptionsScreen():['overview','selection','completed-year','expanded-year','empty'].contains(scene)?_FixtureOverview(scene):_FixtureMonth(scene);
  final boundary=GlobalKey();
  await tester.pumpWidget(RepaintBoundary(key:boundary,child:MaterialApp(theme:dark?ComponentTheme.darkTheme():ComponentTheme.lightTheme(),debugShowCheckedModeBanner:false,localizationsDelegates:StringsLocalizations.localizationsDelegates,supportedLocales:StringsLocalizations.supportedLocales,builder:(context,child)=>MediaQuery(data:MediaQuery.of(context).copyWith(padding:const EdgeInsets.only(top:44,bottom:24)),child:child!),home:page)));
  await tester.pumpAndSettle();
  TestGesture? heldGesture;
  if(scene=='keep-swipe'||scene=='delete-swipe'){heldGesture=await tester.startGesture(tester.getCenter(find.byType(ReviewSwipeStack)));await heldGesture.moveBy(Offset(scene=='keep-swipe'?30:-30,0));await tester.pump();await heldGesture.moveBy(Offset(scene=='keep-swipe'?110:-110,8));await tester.pump();}
  if(scene=='confirmation'){
   final context=tester.element(find.byType(_FixtureMonth));
   unawaited(showDeleteConfirmationSheet(context,files:_fixtureFiles.take(3).toList(),isLocal:true,isRemote:true,count:3,onDeleteFromLocal:()async=>false,onDeleteFromRemote:()async=>false,onDeleteFromBoth:()async=>false));
   await tester.pumpAndSettle();
  }
  await tester.runAsync(()async{await Future<void>.delayed(const Duration(milliseconds:300));});await tester.pumpAndSettle();
  expect(tester.takeException(),isNull);
  await tester.runAsync(()async{final image=await (boundary.currentContext!.findRenderObject() as RenderRepaintBoundary).toImage(pixelRatio:2);final bytes=await image.toByteData(format:ui.ImageByteFormat.png);await File('${Platform.environment['ENTE_REVIEW_EVIDENCE_DIR'] ?? '/tmp/ente-pr46-evidence'}/$scene-${dark?'dark':'light'}.png').writeAsBytes(bytes!.buffer.asUint8List());image.dispose();});
  await tester.pumpWidget(const SizedBox());await heldGesture?.cancel();await tester.pump(const Duration(milliseconds:100));debugDisableShadows=true;
 });}}
}
