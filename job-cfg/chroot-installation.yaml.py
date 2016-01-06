#!/usr/bin/python

import sys
import os
from string import join
from yaml import load, dump
try:
    from yaml import CLoader as Loader, CDumper as Dumper
except ImportError:
    from yaml import Loader, Dumper


base_distros = [
    'squeeze',
    'wheezy',
    'jessie',
    'stretch',
    'sid',
    ]

distro_upgrades = {
    'squeeze': 'wheezy',
    'wheezy':  'jessie',
    'jessie':  'stretch',
    'stretch': 'sid',
    }

oldoldstable = 'squeeze'

# ftp.de.debian.org runs mirror updates at 03:25, 09:25, 15:25 and 21:25 UTC and usually they run 10m...
trigger_times = {
    'squeeze': '30 16 25 * *',
    'wheezy':  '30 16 1,15 * *',
    'jessie':  '30 10 * * 1,4',
    'stretch': '30 10 */2 * *',
    'sid':     '30 4 * * *',
    }

all_targets = [
   'gnome',
   'kde',
   'kde-full',
   'cinnamon',
   'lxde',
   'xfce',
   'full_desktop',
   'qt4',
   'qt5',
   'haskell',
   'developer',
   'education-tasks',
   'education-menus',
   'education-astronomy',
   'education-chemistry',
   'education-common',
   'education-desktop-gnome',
   'education-desktop-kde',
   'education-desktop-lxde',
   'education-desktop-mate',
   'education-desktop-other',
   'education-desktop-sugar',
   'education-desktop-xfce',
   'education-development',
   'education-electronics',
   'education-geography',
   'education-graphics',
   'education-language',
   'education-laptop',
   'education-logic-games',
   'education-main-server',
   'education-mathematics',
   'education-misc',
   'education-music',
   'education-networked',
   'education-physics',
   'education-services',
   'education-standalone',
   'education-thin-client',
   'education-thin-client-server',
   'education-workstation',
   ]

#
# not all packages are available in all distros
#
def is_target_in_distro(distro, target):
         # haskell, cinnamon, qt5 and edu tests not in squeeze
         if distro == 'squeeze' and ( target == 'haskell' or target[:10] == 'education-' or target == 'cinnamon' or target == 'qt5' ):
             return False
         # qt5, education-desktop-mate and cinnamon weren't in wheezy
         if distro == 'wheezy' and ( target == 'education-desktop-mate' or target == 'cinnamon' or target == 'qt5' ):
             return False
         # sugar has been removed from jessie and thus education-desktop-sugar has been removed from jessie and sid - it's also not yet available in stretch again...
         if (distro == 'sid' or distro == 'jessie' or distro == 'stretch') and ( target == 'education-desktop-sugar' ):
             return False
         return True

#
# return the list of targets, filtered to be those present in 'distro'
#
def get_targets_in_distro(distro):
     return [t for t in all_targets if is_target_in_distro(distro, t)]

#
# given a target, returns a list of ([dist], key) tuples, so we can handle the
# edu packages having views that are distro dependant
#
# this groups all the distros that have matching views
#
def get_dists_per_key(target,get_distro_key):
    dists_per_key = {}
    for distro in base_distros:
        if is_target_in_distro(distro, target):
            key = get_distro_key(distro)
            if key not in dists_per_key.keys():
                dists_per_key[key] = []
            dists_per_key[key].append(distro)
    return dists_per_key

#
# who gets mail for which target
#
def get_recipients(target):
    if target == 'haskell':
        return 'jenkins+debian-haskell qa-jenkins-scm@lists.alioth.debian.org pkg-haskell-maintainers@lists.alioth.debian.org'
    elif target == 'gnome':
        return 'jenkins+debian-qa pkg-gnome-maintainers@lists.alioth.debian.org qa-jenkins-scm@lists.alioth.debian.org'
    elif target == 'cinnamon':
        return 'jenkins+debian-cinnamon pkg-cinnamon-team@lists.alioth.debian.org qa-jenkins-scm@lists.alioth.debian.org'
    elif target[:3] == 'kde' or target[:2] == 'qt':
        return 'jenkins+debian-qa debian-qt-kde@lists.debian.org qa-jenkins-scm@lists.alioth.debian.org'
    elif target[:10] == 'education-':
        return 'jenkins+debian-edu debian-edu-commits@lists.alioth.debian.org'
    else:
        return 'jenkins+debian-qa qa-jenkins-scm@lists.alioth.debian.org'

#
# views for different targets
#
def get_view(target, distro):
    if target == 'haskell':
        return 'haskell'
    elif target[:10] == 'education-':
        if distro in ('squeeze', 'wheezy'):
            return 'edu_stable'
        else:
            return 'edu_devel'
    else:
        return 'chroot-installation'

#
# special descriptions used for some targets
#
spoken_names = {
    'gnome': 'GNOME',
    'kde': 'KDE plasma desktop',
    'kde-full': 'complete KDE desktop',
    'cinnamon': 'Cinnamon',
    'lxde': 'LXDE',
    'xfce': 'Xfce',
    'qt4': 'Qt4 cross-platform C++ application framework',
    'qt5': 'Qt5 cross-platform C++ application framework',
    'full_desktop': 'four desktop environments and the most commonly used applications and packages',
    'haskell': 'all Haskell related packages',
    'developer': 'four desktop environments and the most commonly used applications and packages - and the build depends for all of these',
    }
def get_spoken_name(target):
    if target[:10] == 'education-':
         return 'the Debian Edu metapackage '+target
    elif target in spoken_names:
         return spoken_names[target]
    else:
         return target

#
# This structure contains the differences between the default, upgrade and upgrade_apt+dpkg_first jobs
#
jobspecs = [
    { 'j_ext': '',
      'd_ext': '',
      's_ext': '',
      'dist_func': (lambda d: d),
      'distfilter': (lambda d: tuple(set(d) - set([oldoldstable]))),
      'skiptaryet': (lambda t: False)
    },
    { 'j_ext': '_upgrade_to_{dist2}',
      'd_ext': ', then upgrade to {dist2}',
      's_ext': ' {dist2}',
      'dist_func': (lambda d: [{dist: {'dist2': distro_upgrades[dist]}} for dist in d]),
      'distfilter': (lambda d: tuple(set(d) & set(distro_upgrades))),
      'skiptaryet': (lambda t: False)
    },
    { 'j_ext': '_upgrade_to_{dist2}_aptdpkg_first',
      'd_ext': ', then upgrade apt and dpkg to {dist2} and then everything else',
      's_ext': ' {dist2}',
      'dist_func': (lambda d: [{dist: {'dist2': distro_upgrades[dist]}} for dist in d]),
      'distfilter': (lambda d: tuple((set(d) & set(distro_upgrades)) - set([oldoldstable]))),
      'skiptaryet': (lambda t: t[:10] == 'education-')
    },
]

#
# nothing to edit below
#

data = []
jobs = []

data.append(
   {   'defaults': {   'builders': [{   'shell': '{my_shell}'}],
                        'description': '{my_description}{do_not_edit}',
                        'logrotate': {   'artifactDaysToKeep': -1,
                                         'artifactNumToKeep': -1,
                                         'daysToKeep': 90,
                                         'numToKeep': 30},
                        'name': 'chroot-installation',
                        'properties': [   {   'sidebar': {   'icon': '/userContent/images/debian-swirl-24x24.png',
                                                             'text': 'About jenkins.debian.net',
                                                             'url': 'https://jenkins.debian.net/userContent/about.html'}},
                                          {   'sidebar': {   'icon': '/userContent/images/debian-jenkins-24x24.png',
                                                             'text': 'All {my_view} jobs',
                                                             'url': 'https://jenkins.debian.net/view/{my_view}/'}},
                                          {   'sidebar': {   'icon': '/userContent/images/profitbricks-24x24.png',
                                                             'text': 'Sponsored by Profitbricks',
                                                             'url': 'http://www.profitbricks.co.uk'}},
                                          {   'priority-sorter': {   'priority': '{my_prio}'}},
                                          {   'throttle': {   'categories': [   'chroot-installation'],
                                                              'enabled': True,
                                                              'max-per-node': 6,
                                                              'max-total': 6,
                                                              'option': 'category'}}],
                        'publishers': [   {   'trigger': {   'project': '{my_trigger}'}},
                                          {   'logparser': {   'fail-on-error': 'false',
                                                               'parse-rules': '/srv/jenkins/logparse/debian.rules',
                                                               'unstable-on-warning': 'false'}},
                                          {   'email-ext': {   'attach-build-log': False,
                                                               'body': 'See $BUILD_URL/console or just $BUILD_URL for more information.',
                                                               'first-failure': True,
                                                               'fixed': True,
                                                               'recipients': '{my_recipients}',
                                                               'subject': '$BUILD_STATUS: $JOB_NAME/$BUILD_NUMBER'}}],
                        'triggers': [{   'timed': '{my_time}'}],
                        'wrappers': [{   'timeout': {   'timeout': 360}}]}})
data.append(
    {   'job-template': {   'defaults': 'chroot-installation',
                            'name': '{name}_{dist}_{action}'}})
data.append(
    {   'job-template': {   'defaults': 'chroot-installation',
                            'name': '{name}_{dist}_install_{target}'}})
data.append(
    {   'job-template': {   'defaults': 'chroot-installation',
                            'name': '{name}_{dist}_{action}_upgrade_to_{dist2}'}})
data.append(
    {   'job-template': {   'defaults': 'chroot-installation',
                            'name': '{name}_{dist}_install_{target}_upgrade_to_{dist2}'}})
data.append(
    {   'job-template': {   'defaults': 'chroot-installation',
                            'name': '{name}_{dist}_{action}_upgrade_to_{dist2}_aptdpkg_first'}})
data.append(
    {   'job-template': {   'defaults': 'chroot-installation',
                            'name': '{name}_{dist}_install_{target}_upgrade_to_{dist2}_aptdpkg_first'}})

# maintenance jobs
maint_distros = []
for base_distro in sorted(base_distros):
    dist2 = ''
    if base_distro in distro_upgrades.values():
        trigger = 'chroot-installation_{dist}_bootstrap'
        for item in distro_upgrades.items():
            if item[1]==base_distro and base_distro in distro_upgrades:
                trigger = trigger+', chroot-installation_{dist}_bootstrap_upgrade_to_{dist2}, chroot-installation_{dist}_bootstrap_upgrade_to_{dist2}_aptdpkg_first'
                dist2 = distro_upgrades[base_distro]
    else:
        trigger = 'chroot-installation_{dist}_bootstrap_upgrade_to_{dist2}'
        dist2 = distro_upgrades[base_distro]
    maint_distros.append({ base_distro: {
                              'my_time': trigger_times[base_distro],
                              'dist2': dist2,
                              'my_trigger': trigger}})
jobs.append({ '{name}_{dist}_{action}': {
                  'action': 'maintenance',
                  'dist': maint_distros,
                  'my_description': 'Maintainance job for chroot-installation_{dist}_* jobs, do some cleanups and monitoring so that there is a predictable environment.',
                  'my_prio': '135',
                  'my_recipients': 'qa-jenkins-scm@lists.alioth.debian.org',
                  'my_shell': '/srv/jenkins/bin/maintenance.sh chroot-installation_{dist}',
                  'my_view': 'jenkins.d.n'}})


# bootstrap jobs
js_dists_trigs = [{},{},{}]
for trigs, dists in get_dists_per_key('bootstrap',(lambda d: tuple(sorted(get_targets_in_distro(d))))).items():
    for jobindex, jobspec in enumerate(jobspecs):
        js_dists = jobspec['distfilter'](dists)
        if (js_dists):
            js_disttrig = tuple((tuple(js_dists), trigs))
            js_dists_trigs[jobindex][js_disttrig] = True


for jobindex, jobspec in enumerate(jobspecs):
    jobs.extend([{ '{name}_{dist}_{action}'+jobspec['j_ext']: {
                      'action': 'bootstrap',
                      'dist': list(dists) if jobspec['j_ext'] == '' else
                              [{dist: {'dist2': distro_upgrades[dist]}} for dist in dists],
                      'my_trigger': join(['chroot-installation_{dist}_install_'+t+jobspec['j_ext']
                                          for t in list(trigs)], ', '),
                      'my_description': 'Debootstrap {dist}'+jobspec['d_ext']+'.',
                      'my_prio': 131,
                      'my_time': '',
                      'my_recipients': get_recipients('bootstrap'),
                      'my_shell': '/srv/jenkins/bin/chroot-installation.sh {dist} none'+jobspec['s_ext'],
                      'my_view': get_view('bootstrap', None),
                  }}
                  for (dists, trigs) in js_dists_trigs[jobindex].keys()])

# now all the other jobs
targets_per_distview = [{},{},{}]
for target in sorted(all_targets):
    for view, dists in get_dists_per_key(target,(lambda d: get_view(target, d))).items():
        for jobindex, jobspec in enumerate(jobspecs):
            if jobspec['skiptaryet'](target):
                continue

            js_dists = jobspec['distfilter'](dists)
            if (js_dists):
                distview = tuple((tuple(js_dists), view))
                if distview not in targets_per_distview[jobindex].keys():
                    targets_per_distview[jobindex][distview] = []
                targets_per_distview[jobindex][distview].append(target)

for jobindex, jobspec in enumerate(jobspecs):
    jobs.extend([{ '{name}_{dist}_install_{target}'+jobspec['j_ext']: {
                  'dist': jobspec['dist_func'](list(dists)),
                  'target': [{t: {
                                 'my_spokenname': get_spoken_name(t),
                                 'my_recipients': get_recipients(t)}}
                             for t in dv_targs],
                  'my_description': 'Debootstrap {dist}, then install {my_spokenname}'+jobspec['d_ext']+'.',
                  'my_shell': '/srv/jenkins/bin/chroot-installation.sh {dist} {target}'+jobspec['s_ext'],
                  'my_view': view,
                  }}
                  for (dists, view), dv_targs in targets_per_distview[jobindex].items()])

data.append({'project': {
                 'name': 'chroot-installation',
                 'do_not_edit': '<br><br>Job configuration source is <a href="http://anonscm.debian.org/cgit/qa/jenkins.debian.net.git/tree/job-cfg/chroot-installation.yaml.py">chroot-installation.yaml.py</a>.',
                 'my_prio': '130',
                 'my_trigger': '',
                 'my_time': '',
                 'jobs': jobs}})

sys.stdout.write(dump(data, Dumper=Dumper))
