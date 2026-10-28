from pathlib import Path
import re,sys
root=Path(sys.argv[1]).resolve() if len(sys.argv)>1 else Path.cwd()
out=Path(__file__).resolve().parent
paths=['mobile/apps/photos/lib/ui/tools/photo_review/review_month_page.dart','mobile/apps/photos/lib/ui/tools/photo_review/review_old_photos_page.dart','mobile/apps/photos/lib/ui/settings/backup/free_space_options.dart']
imports=set(); bodies=[]
for p in paths:
 s=(root/p).read_text()
 for imp in re.findall(r'^import .*?;',s,re.M|re.S):
  if 'package:photos/ui/tools/photo_review/review_month_page.dart' not in imp and 'package:photos/ui/tools/photo_review/review_old_photos_page.dart' not in imp: imports.add(imp)
 s=re.sub(r'^import .*?;\n','',s,flags=re.M|re.S)
 s=s.replace('if (flagService.internalUser)','if (_fixtureFeatureEnabled)').replace('if (flagService.enableVectorDb)','if (true)')
 bodies.append(s)
extra='''
import "dart:ui" as ui;
import "package:flutter/rendering.dart";
import "package:flutter_test/flutter_test.dart";
import "package:shared_preferences/shared_preferences.dart";
import "package:photos/settings/local_settings.dart";
import "package:photos/core/cache/thumbnail_in_memory_cache.dart";
import "package:photos/core/constants.dart";
import "package:photos/models/file/file_type.dart";
'''
(out/'fixture_test.dart').write_text('\n'.join(sorted(imports))+'\n'+extra+'\n'+'\n'.join(bodies)+'\n'+(out/'harness_tail.dart').read_text())
