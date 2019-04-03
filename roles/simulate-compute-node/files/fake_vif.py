# special subclass of FakeDriver that also adds OVS controls.
# this file should be copied into the Nova installation in the local
# Python, such as /usr/lib/python2.7/site-packages/nova/virt/fake_vif.py
# It then can be invoked from nova.conf via
# compute_driver=fake_vif.OVSFakeDriver

import eventlet

from oslo_log import log as logging
from oslo_utils import excutils

import nova.conf
from nova import exception
from nova import utils
from nova.virt import fake


CONF = nova.conf.CONF

LOG = logging.getLogger(__name__)


def _ovs_vsctl(args):
    full_args = ["ovs-vsctl", "--timeout=%s" % CONF.ovs_vsctl_timeout] + args
    LOG.info(
        "running ovs-vsctl command: %s",
        " ".join(str(arg) for arg in full_args),
    )
    try:
        return utils.execute(*full_args, run_as_root=True)
    except Exception as e:
        LOG.error(
            "Unable to execute %(cmd)s. Exception: %(exception)s",
            {"cmd": full_args, "exception": e},
        )
        raise exception.OvsConfigurationFailure(inner_exception=e)


class OVSFakeDriver(fake.FakeDriver):
    def __init__(self, *arg, **kw):
        LOG.info("Spinning up OVSFakeDriver")
        super(OVSFakeDriver, self).__init__(*arg, **kw)

    def spawn(
        self,
        context,
        instance,
        image_meta,
        injected_files,
        admin_password,
        allocations,
        network_info=None,
        block_device_info=None,
    ):
        self._create_domain_and_network(
            context, instance, network_info,
            block_device_info=block_device_info,
            destroy_disks_on_failure=True)

        return super(OVSFakeDriver, self).spawn(
            context,
            instance,
            image_meta,
            injected_files,
            admin_password,
            allocations,
            network_info=network_info,
            block_device_info=block_device_info,
        )

    def destroy(
        self,
        context,
        instance,
        network_info,
        block_device_info=None,
        destroy_disks=True,
    ):
        self.cleanup(context, instance, network_info, block_device_info,
                     destroy_disks)

    def _cleanup_failed_start(self, context, instance, network_info,
                              block_device_info, guest, destroy_disks):
        try:
            if guest and guest.is_active():
                guest.poweroff()
        finally:
            self.cleanup(context, instance, network_info=network_info,
                         block_device_info=block_device_info,
                         destroy_disks=destroy_disks)

    def cleanup(self, context, instance, network_info, block_device_info=None,
                destroy_disks=True, migrate_data=None, destroy_vifs=True):
        if destroy_vifs:
            self._unplug_vifs(instance, network_info, True)

    def plug_vif(self, instance, vif):
        bridge = "br-int"
        dev = vif.get("devname")
        port = vif.get("id")
        mac_address = vif.get("address")
        if not dev or not port or not mac_address:
            return
        else:
            cmds = [
                ["--", "--may-exist", "add-port", bridge, dev],
                ["--", "set", "Interface", dev, "type=internal"],
                [
                    "--",
                    "set",
                    "Interface",
                    dev,
                    "external-ids:iface-id=%s" % port,
                ],
                [
                    "--",
                    "set",
                    "Interface",
                    dev,
                    "external-ids:iface-status=active",
                ],
                [
                    "--",
                    "set",
                    "Interface",
                    dev,
                    "external-ids:attached-mac=%s" % mac_address,
                ],
            ]
            _ovs_vsctl(sum(cmds, []))

    def plug_vifs(self, instance, network_info):
        """Plug VIFs into networks."""
        for vif in network_info:
            self.plug_vif(instance, vif)

    def unplug_vif(self, instance, vif):
        bridge = "br-int"
        dev = vif.get("devname")
        port = vif.get("id")
        if not dev:
            if not port:
                return
            dev = "tap" + str(port[0:11])
        _ovs_vsctl(["--", "--if-exists", "del-port", bridge, dev])

    def unplug_vifs(self, instance, network_info):
        """Unplug VIFs from networks."""

        for vif in network_info:
            self.unplug_vif(instance, vif)

    def _neutron_failed_callback(self, event_name, instance):
        LOG.error('Neutron Reported failure on event '
                  '%(event)s for instance %(uuid)s',
                  {'event': event_name, 'uuid': instance.uuid},
                  instance=instance)
        if CONF.vif_plugging_is_fatal:
            raise exception.VirtualInterfaceCreateException()

    def _get_neutron_events(self, network_info):
        # NOTE(danms): We need to collect any VIFs that are currently
        # down that we expect a down->up event for. Anything that is
        # already up will not undergo that transition, and for
        # anything that might be stale (cache-wise) assume it's
        # already up so we don't block on it.
        return [('network-vif-plugged', vif['id'])
                for vif in network_info if vif.get('active', True) is False]

    def _create_domain_and_network(self, context, instance, network_info,
                                   block_device_info=None, power_on=True,
                                   vifs_already_plugged=False,
                                   destroy_disks_on_failure=False):

        """Do required network setup and create domain."""
        timeout = CONF.vif_plugging_timeout
        if (utils.is_neutron() and not
            vifs_already_plugged and power_on and timeout):
            events = self._get_neutron_events(network_info)
        else:
            events = []

        pause = bool(events)
        guest = None
        try:
            with self.virtapi.wait_for_instance_event(
                    instance, events, deadline=timeout,
                    error_callback=self._neutron_failed_callback):
                self.plug_vifs(instance, network_info)
        except exception.VirtualInterfaceCreateException:
            # Neutron reported failure and we didn't swallow it, so
            # bail here
            with excutils.save_and_reraise_exception():
                self._cleanup_failed_start(context, instance, network_info,
                                           block_device_info, guest,
                                           destroy_disks_on_failure)
        except eventlet.timeout.Timeout:
            # We never heard from Neutron
            LOG.warning('Timeout waiting for %(events)s for '
                        'instance with vm_state %(vm_state)s and '
                        'task_state %(task_state)s.',
                        {'events': events,
                         'vm_state': instance.vm_state,
                         'task_state': instance.task_state},
                        instance=instance)
            if CONF.vif_plugging_is_fatal:
                self._cleanup_failed_start(context, instance, network_info,
                                           block_device_info, guest,
                                           destroy_disks_on_failure)
                raise exception.VirtualInterfaceCreateException()
        except Exception:
            # Any other error, be sure to clean up
            LOG.error('Failed to start libvirt guest', instance=instance)
            with excutils.save_and_reraise_exception():
                self._cleanup_failed_start(context, instance, network_info,
                                           block_device_info, guest,
                                           destroy_disks_on_failure)

        # Resume only if domain has been paused
        if pause:
            guest.resume()
        return guest
