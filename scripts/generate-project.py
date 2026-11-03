#!/usr/bin/env python3
"""Generate a deterministic native macOS Xcode application project. No dependencies."""
import hashlib
from pathlib import Path
root=Path(__file__).resolve().parents[1]
def uid(s): return hashlib.sha256(s.encode()).hexdigest()[:24].upper()
objects=[]
def obj(name,value):
    ident=uid(name); objects.append(f'{ident} = {{ {value} }};'); return ident
files=sorted((root/'Sources/OpenCompanion').glob('*.swift'))
source_ids=[]; file_ids=[]
for path in files:
    ref=obj('ref'+path.name,f'isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = "{path.relative_to(root)}"; sourceTree = SOURCE_ROOT;');file_ids.append(ref)
    source_ids.append(obj('build'+path.name,f'isa = PBXBuildFile; fileRef = {ref};'))
app=obj('app','isa = PBXFileReference; explicitFileType = wrapper.application; path = OpenCompanion.app; sourceTree = BUILT_PRODUCTS_DIR;')
icon=obj('icon','isa = PBXFileReference; lastKnownFileType = image.icns; path = App/AppIcon.icns; sourceTree = SOURCE_ROOT;')
icon_build=obj('iconbuild',f'isa = PBXBuildFile; fileRef = {icon};')
sources=obj('sources',f'isa = PBXSourcesBuildPhase; buildActionMask = 2147483647; files = ({",".join(source_ids)},); runOnlyForDeploymentPostprocessing = 0;')
package=obj('package','isa = XCLocalSwiftPackageReference; relativePath = ".";')
core=obj('core',f'isa = XCSwiftPackageProductDependency; package = {package}; productName = CompanionCore;')
store=obj('store',f'isa = XCSwiftPackageProductDependency; package = {package}; productName = CompanionStore;')
framework_ids=[obj('link'+name,f'isa = PBXBuildFile; productRef = {ident};') for name,ident in [('core',core),('store',store)]]
frameworks=obj('frameworks',f'isa = PBXFrameworksBuildPhase; buildActionMask = 2147483647; files = ({",".join(framework_ids)},); runOnlyForDeploymentPostprocessing = 0;')
resources=obj('resources',f'isa = PBXResourcesBuildPhase; buildActionMask = 2147483647; files = ({icon_build},); runOnlyForDeploymentPostprocessing = 0;')
products=obj('products',f'isa = PBXGroup; children = ({app},); name = Products; sourceTree = "<group>";')
group=obj('group',f'isa = PBXGroup; children = ({",".join(file_ids)},{icon},{products},); sourceTree = "<group>";')
def configs(name,settings):
    ids=[]
    for config in ['Debug','Release']:
        optim='SWIFT_OPTIMIZATION_LEVEL = "-Onone"; DEBUG_INFORMATION_FORMAT = dwarf;' if config=='Debug' else 'SWIFT_OPTIMIZATION_LEVEL = "-O"; DEBUG_INFORMATION_FORMAT = "dwarf-with-dsym";'
        ids.append(obj(name+config,f'isa = XCBuildConfiguration; name = {config}; buildSettings = {{ {settings} {optim} }};'))
    return obj(name+'list',f'isa = XCConfigurationList; buildConfigurations = ({",".join(ids)},); defaultConfigurationIsVisible = 0; defaultConfigurationName = Release;')
project_config=configs('project','SDKROOT = macosx; MACOSX_DEPLOYMENT_TARGET = 14.2; SWIFT_VERSION = 6.0; CLANG_ENABLE_MODULES = YES;')
target_config=configs('target','PRODUCT_NAME = OpenCompanion; PRODUCT_BUNDLE_IDENTIFIER = org.opencompanion.mac; INFOPLIST_FILE = App/Info.plist; CODE_SIGN_ENTITLEMENTS = App/OpenCompanion.entitlements; CODE_SIGN_IDENTITY = "-"; CODE_SIGN_STYLE = Manual; ARCHS = arm64; ENABLE_HARDENED_RUNTIME = NO; LD_RUNPATH_SEARCH_PATHS = "$(inherited) @executable_path/../Frameworks";')
target=obj('target',f'isa = PBXNativeTarget; buildConfigurationList = {target_config}; buildPhases = ({sources},{frameworks},{resources},); buildRules = (); dependencies = (); name = OpenCompanion; packageProductDependencies = ({core},{store},); productName = OpenCompanion; productReference = {app}; productType = "com.apple.product-type.application";')
project=obj('project',f'isa = PBXProject; attributes = {{ LastUpgradeCheck = 2700; }}; buildConfigurationList = {project_config}; compatibilityVersion = "Xcode 14.0"; developmentRegion = en; hasScannedForEncodings = 0; knownRegions = (en,Base); mainGroup = {group}; packageReferences = ({package},); productRefGroup = {products}; projectDirPath = ""; projectRoot = ""; targets = ({target},);')
folder=root/'OpenCompanion.xcodeproj';folder.mkdir(exist_ok=True)
(folder/'project.pbxproj').write_text('// !$*UTF8*$!\n{ archiveVersion = 1; classes = {}; objectVersion = 60; objects = {\n'+'\n'.join(objects)+f'\n}}; rootObject = {project}; }}\n')
schemes=folder/'xcshareddata/xcschemes';schemes.mkdir(parents=True,exist_ok=True)
(schemes/'OpenCompanion.xcscheme').write_text(f'''<?xml version="1.0" encoding="UTF-8"?><Scheme LastUpgradeVersion="2700" version="1.3"><BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES"><BuildActionEntries><BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES"><BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{target}" BuildableName="OpenCompanion.app" BlueprintName="OpenCompanion" ReferencedContainer="container:OpenCompanion.xcodeproj"/></BuildActionEntry></BuildActionEntries></BuildAction><LaunchAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO" debugDocumentVersioning="YES" allowLocationSimulation="YES"><BuildableProductRunnable runnableDebuggingMode="0"><BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{target}" BuildableName="OpenCompanion.app" BlueprintName="OpenCompanion" ReferencedContainer="container:OpenCompanion.xcodeproj"/></BuildableProductRunnable></LaunchAction></Scheme>''')
print(f'Generated project with {len(files)} app sources')
