#!/usr/bin/env python3
"""Deterministic, dependency-free Xcode project generation from the source tree."""
import hashlib
import json
from pathlib import Path
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parent.parent
objects = {}
def ident(key): return hashlib.sha1(key.encode()).hexdigest()[:24].upper()
def add(key, value):
    key = ident(key)
    objects[key] = value
    return key
def quote(value): return json.dumps(str(value))
def serialize(value, level=0):
    if isinstance(value, dict):
        return '{\n' + ''.join('\t' * (level+1) + str(k) + ' = ' + serialize(v,level+1) + ';\n' for k,v in value.items()) + '\t' * level + '}'
    if isinstance(value, list): return '(' + ', '.join(serialize(x,level+1) for x in value) + (',' if value else '') + ')'
    return quote(value)

base = add('baseconfig',dict(isa='PBXFileReference',lastKnownFileType='text.xcconfig',path='Config/Base.xcconfig',sourceTree='<group>'))
info = add('info',dict(isa='PBXFileReference',lastKnownFileType='text.plist.xml',path='Config/Persisted-Info.plist',sourceTree='<group>'))
icon = add('icon',dict(isa='PBXFileReference',lastKnownFileType='image.icns',path='Config/Persisted.icns',sourceTree='<group>'))
products = []
groups = []
targets = []
for name, folder, kind, extension, deps in [
    ('PersistedCore','Sources/PersistedCore','framework','framework',[]),
    ('PersistedSpacesBridge','Sources/PersistedSpacesBridge','library.static','a',[]),
    ('PersistedPlatform','Sources/PersistedPlatform','framework','framework',['PersistedCore','PersistedSpacesBridge']),
    ('Persisted','Sources/Persisted','application','app',['PersistedCore','PersistedPlatform']),
    ('PersistedHarness','Sources/PersistedHarness','application','app',[]),
    ('PersistedCoreTests','Tests/PersistedCoreTests','bundle.unit-test','xctest',['PersistedCore']),
]:
    files = []
    sourcebuilds = []
    for path in sorted(path for path in (ROOT/folder).rglob('*') if path.suffix in ['.swift', '.m', '.h']):
        relative = str(path.relative_to(ROOT))
        ref = add(relative,dict(isa='PBXFileReference',lastKnownFileType={'.swift':'sourcecode.swift','.m':'sourcecode.c.objc','.h':'sourcecode.c.h'}[path.suffix],path=relative,sourceTree='<group>'))
        files.append(ref)
        if path.suffix != '.h': sourcebuilds.append(add('build'+relative,dict(isa='PBXBuildFile',fileRef=ref)))
    groups.append(add('group'+name,dict(isa='PBXGroup',name=name,children=files,sourceTree='<group>')))
    product = add('product'+name,dict(isa='PBXFileReference',explicitFileType={'framework':'wrapper.framework','app':'wrapper.application','xctest':'wrapper.cfbundle','a':'archive.ar'}[extension],path=('lib' if extension=='a' else '')+name+'.'+extension,sourceTree='BUILT_PRODUCTS_DIR'))
    products.append(product)
    sources = add('sources'+name,dict(isa='PBXSourcesBuildPhase',buildActionMask='2147483647',files=sourcebuilds,runOnlyForDeploymentPostprocessing='0'))
    frameworks = add('frameworks'+name,dict(isa='PBXFrameworksBuildPhase',buildActionMask='2147483647',files=[add('link'+name+dep,dict(isa='PBXBuildFile',fileRef=ident('product'+dep))) for dep in deps],runOnlyForDeploymentPostprocessing='0'))
    phases=[sources,frameworks]
    if name=='Persisted':
        phases.append(add('resources'+name,dict(isa='PBXResourcesBuildPhase',buildActionMask='2147483647',files=[add('iconbuild',dict(isa='PBXBuildFile',fileRef=icon))],runOnlyForDeploymentPostprocessing='0')))
        phases.append(add('embed'+name,dict(isa='PBXCopyFilesBuildPhase',buildActionMask='2147483647',dstPath='',dstSubfolderSpec='10',name='Embed Frameworks',files=[add('embed'+dep,dict(isa='PBXBuildFile',fileRef=ident('product'+dep),settings=dict(ATTRIBUTES=['CodeSignOnCopy','RemoveHeadersOnCopy']))) for dep in deps],runOnlyForDeploymentPostprocessing='0')))
    configurations=[]
    for configuration in ['Debug','Release']:
        settings=dict(PRODUCT_NAME='$(TARGET_NAME)',PRODUCT_BUNDLE_IDENTIFIER='$(PERSISTED_BUNDLE_IDENTIFIER)'+('' if name=='Persisted' else '.Harness' if name=='PersistedHarness' else '.'+name),LD_RUNPATH_SEARCH_PATHS=['$(inherited)','@executable_path/../Frameworks','@loader_path/../Frameworks','$(BUILT_PRODUCTS_DIR)'])
        settings.update(SWIFT_OPTIMIZATION_LEVEL='-Onone' if configuration=='Debug' else '-O',SWIFT_COMPILATION_MODE='singlefile' if configuration=='Debug' else 'wholemodule',DEBUG_INFORMATION_FORMAT='dwarf' if configuration=='Debug' else 'dwarf-with-dsym',ENABLE_TESTABILITY='YES' if configuration=='Debug' else 'NO')
        if configuration=='Debug': settings['SWIFT_ACTIVE_COMPILATION_CONDITIONS']='DEBUG'
        if name=='Persisted': settings['INFOPLIST_FILE']='Config/Persisted-Info.plist'
        else: settings['GENERATE_INFOPLIST_FILE']='YES'
        if kind=='framework': settings.update(DEFINES_MODULE='YES',SKIP_INSTALL='YES',DYLIB_INSTALL_NAME_BASE='@rpath')
        if name=='PersistedSpacesBridge': settings.update(DEFINES_MODULE='YES',SKIP_INSTALL='YES',CLANG_ENABLE_OBJC_ARC='YES',HEADER_SEARCH_PATHS=['$(SRCROOT)/Sources/PersistedSpacesBridge/include'],MODULEMAP_FILE='$(SRCROOT)/Sources/PersistedSpacesBridge/include/module.modulemap')
        if name in ['PersistedPlatform','Persisted']: settings['SWIFT_INCLUDE_PATHS']=['$(SRCROOT)/Sources/PersistedSpacesBridge/include']
        if name=='PersistedCoreTests': settings.update(CODE_SIGNING_ALLOWED='NO',SKIP_INSTALL='YES')
        configurations.append(add('config'+name+configuration,dict(isa='XCBuildConfiguration',baseConfigurationReference=base,buildSettings=settings,name=configuration)))
    configlist=add('configs'+name,dict(isa='XCConfigurationList',buildConfigurations=configurations,defaultConfigurationIsVisible='0',defaultConfigurationName='Release'))
    dependencies=[]
    for dep in deps:
        proxy=add('proxy'+name+dep,dict(isa='PBXContainerItemProxy',containerPortal=ident('project'),proxyType='1',remoteGlobalIDString=ident('target'+dep),remoteInfo=dep))
        dependencies.append(add('dependency'+name+dep,dict(isa='PBXTargetDependency',target=ident('target'+dep),targetProxy=proxy)))
    targets.append(add('target'+name,dict(isa='PBXNativeTarget',buildConfigurationList=configlist,buildPhases=phases,buildRules=[],dependencies=dependencies,name=name,productName=name,productReference=product,productType='com.apple.product-type.'+kind)))

productgroup=add('productgroup',dict(isa='PBXGroup',name='Products',children=products,sourceTree='<group>'))
main=add('maingroup',dict(isa='PBXGroup',children=groups+[base,info,icon,productgroup],sourceTree='<group>'))
configs=[add('project'+configuration,dict(isa='XCBuildConfiguration',baseConfigurationReference=base,buildSettings={},name=configuration)) for configuration in ['Debug','Release']]
configlist=add('projectconfigs',dict(isa='XCConfigurationList',buildConfigurations=configs,defaultConfigurationIsVisible='0',defaultConfigurationName='Release'))
project=add('project',dict(isa='PBXProject',attributes=dict(BuildIndependentTargetsInParallel='YES',LastUpgradeCheck='1600'),buildConfigurationList=configlist,compatibilityVersion='Xcode 14.0',developmentRegion='en',hasScannedForEncodings='0',knownRegions=['en','Base'],mainGroup=main,productRefGroup=productgroup,projectDirPath='',projectRoot='',targets=targets))
result=dict(archiveVersion='1',classes={},objectVersion='56',objects=objects,rootObject=project)
projectpath=ROOT/'Persisted.xcodeproj'
projectpath.mkdir(exist_ok=True)
(projectpath/'project.pbxproj').write_text('// !$*UTF8*$!\n'+serialize(result)+'\n')

def buildref(parent,name):
    return ET.SubElement(parent,'BuildableReference',dict(BuildableIdentifier='primary',BlueprintIdentifier=ident('target'+name),BuildableName=name+('.xctest' if name.endswith('Tests') else '.app'),BlueprintName=name,ReferencedContainer='container:Persisted.xcodeproj'))
for name in ['Persisted','PersistedHarness']:
    scheme=ET.Element('Scheme',dict(LastUpgradeVersion='1600',version='1.3'))
    action=ET.SubElement(scheme,'BuildAction',dict(parallelizeBuildables='YES',buildImplicitDependencies='YES'))
    entries=ET.SubElement(action,'BuildActionEntries')
    entry=ET.SubElement(entries,'BuildActionEntry',dict(buildForTesting='YES',buildForRunning='YES',buildForProfiling='YES',buildForArchiving='YES',buildForAnalyzing='YES'))
    buildref(entry,name)
    test=ET.SubElement(scheme,'TestAction',dict(buildConfiguration='Debug',selectedDebuggerIdentifier='Xcode.DebuggerFoundation.Debugger.LLDB',selectedLauncherIdentifier='Xcode.IDEFoundation.Launcher.LLDB',shouldUseLaunchSchemeArgsEnv='YES'))
    testables=ET.SubElement(test,'Testables')
    if name=='Persisted':
        testable=ET.SubElement(testables,'TestableReference',dict(skipped='NO'))
        buildref(testable,'PersistedCoreTests')
    for tag,configuration in [('LaunchAction','Debug'),('ProfileAction','Release')]:
        node=ET.SubElement(scheme,tag,dict(buildConfiguration=configuration,selectedDebuggerIdentifier='Xcode.DebuggerFoundation.Debugger.LLDB',selectedLauncherIdentifier='Xcode.IDEFoundation.Launcher.LLDB',launchStyle='0',useCustomWorkingDirectory='NO',ignoresPersistentStateOnLaunch='NO',debugDocumentVersioning='YES'))
        runnable=ET.SubElement(node,'BuildableProductRunnable',dict(runnableDebuggingMode='0'))
        buildref(runnable,name)
    ET.SubElement(scheme,'AnalyzeAction',dict(buildConfiguration='Debug'))
    ET.SubElement(scheme,'ArchiveAction',dict(buildConfiguration='Release',revealArchiveInOrganizer='YES'))
    ET.indent(scheme)
    schemes=projectpath/'xcshareddata'/'xcschemes'; schemes.mkdir(parents=True,exist_ok=True)
    ET.ElementTree(scheme).write(schemes/(name+'.xcscheme'),encoding='UTF-8',xml_declaration=True)
print('Generated Persisted.xcodeproj and shared schemes.')
