#!/usr/bin/env python3

import os
import sys
import logging
import argparse
import yaml
import re
from azure.identity import DefaultAzureCredential, InteractiveBrowserCredential
from azure.mgmt.subscription import SubscriptionClient
from azure.mgmt.network import NetworkManagementClient
from azure.mgmt.compute import ComputeManagementClient
from azure.mgmt.managementgroups import ManagementGroupsAPI
from pynetbox import api
from pynetbox.core.query import RequestError
import requests

class AzureNetboxConfig:
    """Classe pour gérer la configuration depuis un fichier YAML"""
    
    def __init__(self, config_file=None):
        self.config = self._load_config(config_file)
        self._setup_logging()
    
    def _load_config(self, config_file):
        """Charge la configuration depuis le fichier YAML"""
        if config_file is None:
            config_file = os.path.join(os.path.dirname(__file__), 'config.yaml')
        
        try:
            with open(config_file, 'r', encoding='utf-8') as f:
                config = yaml.safe_load(f)
            print(f"Configuration chargée depuis {config_file}")
            return config
        except FileNotFoundError:
            print(f"Fichier de configuration non trouvé : {config_file}")
            return self._get_default_config()
        except yaml.YAMLError as e:
            print(f"Erreur lors du parsing YAML : {e}")
            sys.exit(1)
    
    def _get_default_config(self):
        """Configuration par défaut si aucun fichier n'est trouvé"""
        return {
            'netbox': {
                'url': os.environ.get('NETBOX_URL', ''),
                'token': os.environ.get('NETBOX_TOKEN', '')
            },
            'azure': {
                'authentication': {'method': 'default'},
                'subscriptions': {'process_all': True}
            },
            'mapping': {
                'site_prefix': 'Azure-',
                'device_type_prefix': 'Azure',
                'device_role_prefix': 'Azure',
                'manufacturer': 'Microsoft Azure',
                'default_interface': 'eth0',
                'max_name_length': 64
            },
            'tags': {
                'sync_tag': {
                    'name': 'azure-sync',
                    'description': 'Synced from Azure'
                }
            },
            'custom_fields': {
                'azure_subscription': {'enabled': True},
                'azure_subscription_url': {'enabled': True}
            },
            'logging': {
                'level': 'INFO',
                'format': '%(asctime)s - %(name)s - %(levelname)s - %(message)s'
            },
            'filters': {
                'regions': {'include': [], 'exclude': []},
                'resource_groups': {'include': [], 'exclude': []},
                'resource_names': {'include_patterns': [], 'exclude_patterns': []}
            },
            'ssl': {'verify': True},
            'timeouts': {'azure_api': 30, 'netbox_api': 30}
        }
    
    def _setup_logging(self):
        """Configure le logging selon la configuration"""
        log_level = getattr(logging, self.config['logging']['level'].upper())
        log_format = self.config['logging']['format']
        
        logging.basicConfig(level=log_level, format=log_format)
        
        # Logger global
        global logger
        logger = logging.getLogger(__name__)
    
    def get_netbox_config(self):
        """Retourne la configuration Netbox"""
        return self.config['netbox']
    
    def get_azure_config(self):
        """Retourne la configuration Azure"""
        return self.config['azure']
    
    def get_mapping_config(self):
        """Retourne la configuration de mapping"""
        return self.config['mapping']
    
    def get_tags_config(self):
        """Retourne la configuration des tags"""
        return self.config['tags']
    
    def get_custom_fields_config(self):
        """Retourne la configuration des champs personnalisés"""
        return self.config['custom_fields']
    
    def get_filters_config(self):
        """Retourne la configuration des filtres"""
        return self.config['filters']
    
    def should_process_resource(self, resource_name, resource_group, region):
        """Vérifie si une ressource doit être traitée selon les filtres"""
        filters = self.get_filters_config()
        
        # Filtre par région
        if filters['regions']['include'] and region not in filters['regions']['include']:
            return False
        if filters['regions']['exclude'] and region in filters['regions']['exclude']:
            return False
        
        # Filtre par groupe de ressources
        if filters['resource_groups']['include'] and resource_group not in filters['resource_groups']['include']:
            return False
        if filters['resource_groups']['exclude'] and resource_group in filters['resource_groups']['exclude']:
            return False
        
        # Filtre par nom de ressource (regex)
        if filters['resource_names']['include_patterns']:
            if not any(re.search(pattern, resource_name) for pattern in filters['resource_names']['include_patterns']):
                return False
        
        if filters['resource_names']['exclude_patterns']:
            if any(re.search(pattern, resource_name) for pattern in filters['resource_names']['exclude_patterns']):
                return False
        
        return True

def truncate_name(name, config):
    """Tronque un nom selon la configuration"""
    max_length = config.get_mapping_config()['max_name_length']
    
    if '.' in name:
        name = name.split('.')[0]
        logger.debug(f"Portion décimale supprimée : {name}")
    
    if len(name) > max_length:
        logger.warning(f"Nom '{name}' dépasse {max_length} caractères, troncature")
        name = name[:max_length]
    
    return name

def get_azure_credentials(config):
    """Obtient les credentials Azure selon la configuration"""
    auth_method = config.get_azure_config()['authentication']['method']
    
    if auth_method == 'interactive':
        logger.info("Utilisation de l'authentification interactive")
        return InteractiveBrowserCredential()
    else:
        logger.info("Utilisation de la chaîne de credentials par défaut")
        return DefaultAzureCredential()

def get_subscriptions_to_process(credential, config):
    """Détermine quels abonnements traiter selon la configuration"""
    azure_config = config.get_azure_config()
    
    if 'management_group' in azure_config['subscriptions']:
        mg_config = azure_config['subscriptions']['management_group']
        return get_management_group_subscriptions(
            credential, 
            mg_config.get('id'), 
            mg_config.get('name')
        )
    elif 'specific_id' in azure_config['subscriptions']:
        subscription_id = azure_config['subscriptions']['specific_id']
        logger.info(f"Traitement uniquement de l'abonnement {subscription_id}")
        return [type('obj', (object,), {
            'subscription_id': subscription_id,
            'display_name': f"Subscription {subscription_id}"
        })]
    else:
        # Traiter tous les abonnements
        return get_azure_subscriptions(credential)

def get_management_group_subscriptions(credential, management_group_id=None, management_group_name=None):
    """Obtient tous les abonnements d'un groupe de gestion"""
    logger.info("Récupération des abonnements du groupe de gestion")
    
    try:
        mg_client = ManagementGroupsAPI(credential)
        
        if management_group_name and not management_group_id:
            logger.info(f"Recherche du groupe de gestion : {management_group_name}")
            management_groups = mg_client.management_groups.list()
            for mg in management_groups:
                if mg.display_name == management_group_name:
                    management_group_id = mg.name
                    logger.info(f"ID du groupe trouvé : {management_group_id}")
                    break
            
            if not management_group_id:
                logger.error(f"Groupe de gestion '{management_group_name}' non trouvé")
                return []
        
        mg_details = mg_client.management_groups.get(
            group_id=management_group_id,
            expand="children",
            recurse=True
        )
        
        subscriptions = []
        
        def extract_subscriptions(mg_node):
            if hasattr(mg_node, 'children') and mg_node.children:
                for child in mg_node.children:
                    if child.type == "/subscriptions":
                        subscription_info = type('obj', (object,), {
                            'subscription_id': child.name,
                            'display_name': child.display_name
                        })
                        subscriptions.append(subscription_info)
                        logger.info(f"Abonnement trouvé : {child.display_name} ({child.name})")
                    elif child.type == "/providers/Microsoft.Management/managementGroups":
                        extract_subscriptions(child)
        
        extract_subscriptions(mg_details)
        
        logger.info(f"{len(subscriptions)} abonnements trouvés dans le groupe")
        return subscriptions
        
    except Exception as e:
        logger.error(f"Erreur lors de la récupération des abonnements : {str(e)}")
        return []

def get_azure_subscriptions(credential):
    """Obtient tous les abonnements Azure accessibles"""
    logger.info("Récupération des abonnements Azure")
    subscription_client = SubscriptionClient(credential)
    subscriptions = list(subscription_client.subscriptions.list())
    logger.info(f"{len(subscriptions)} abonnements trouvés")
    return subscriptions

def get_vnets_and_subnets(subscription_id, credential, config):
    """Obtient tous les VNets et sous-réseaux d'un abonnement"""
    logger.info(f"Récupération des VNets pour l'abonnement {subscription_id}")
    network_client = NetworkManagementClient(credential, subscription_id)
    
    vnets = list(network_client.virtual_networks.list_all())
    logger.info(f"{len(vnets)} VNets trouvés")
    
    vnet_data = []
    for vnet in vnets:
        # Appliquer les filtres
        if not config.should_process_resource(vnet.name, vnet.id.split('/')[4], vnet.location):
            logger.info(f"VNet {vnet.name} ignoré par les filtres")
            continue
            
        vnet_info = {
            'name': vnet.name,
            'id': vnet.id,
            'resource_group': vnet.id.split('/')[4],
            'location': vnet.location,
            'address_space': [prefix for prefix in vnet.address_space.address_prefixes],
            'subnets': []
        }
        
        for subnet in vnet.subnets:
            subnet_info = {
                'name': subnet.name,
                'id': subnet.id,
                'address_prefix': subnet.address_prefix,
                'devices': []
            }
            vnet_info['subnets'].append(subnet_info)
        
        vnet_data.append(vnet_info)
    
    return vnet_data

def sync_to_netbox(all_network_data, config):
    """Synchronise les données réseau Azure vers Netbox"""
    netbox_config = config.get_netbox_config()
    mapping_config = config.get_mapping_config()
    
    logger.info(f"Synchronisation vers Netbox : {netbox_config['url']}")
    
    nb = api(netbox_config['url'], token=netbox_config['token'])
    
    # Configuration SSL
    if not config.config['ssl']['verify']:
        session = requests.Session()
        session.verify = False
        nb.http_session = session
    
    # Setup des champs personnalisés
    setup_custom_fields(nb, config)
    
    # Création du tag de synchronisation
    tags_config = config.get_tags_config()
    azure_tag = get_or_create_tag(
        nb,
        tag_name=tags_config['sync_tag']['name'],
        tag_slug=tags_config['sync_tag']['name'],
        tag_description=tags_config['sync_tag']['description']
    )
    
    # Traitement des données
    for subscription_data in all_network_data:
        process_subscription_data(nb, subscription_data, config, azure_tag)

def setup_custom_fields(nb, config):
    """Configure les champs personnalisés pour l'intégration Azure"""
    custom_fields_config = config.get_custom_fields_config()
    
    if not custom_fields_config['azure_subscription']['enabled']:
        return
    
    logger.info("Configuration des champs personnalisés")
    
    try:
        # NetBox v4.x : utiliser le label 'ipam.prefix' directement
        prefix_content_type = "ipam.prefix"
        
        # Champ abonnement Azure
        get_or_create_custom_field(
            nb,
            field_name="azure_subscription",
            field_type="text",
            field_description="Nom et ID de l'abonnement Azure",
            content_types=[prefix_content_type]
        )
        
        # Champ URL abonnement Azure
        get_or_create_custom_field(
            nb,
            field_name="azure_subscription_url",
            field_type="url",
            field_description="Lien direct vers le portail Azure",
            content_types=[prefix_content_type]
        )
        
        logger.info("Configuration des champs personnalisés terminée")
        
    except Exception as e:
        logger.error(f"Erreur lors de la configuration des champs : {str(e)}", exc_info=True)
#

def get_or_create_custom_field(nb, field_name, field_type, field_description, content_types):
    """Obtient ou crée un champ personnalisé"""
    try:
        custom_field = nb.extras.custom_fields.get(name=field_name)
        if custom_field:
            logger.info(f"Champ personnalisé existant : {field_name}")
            return custom_field
    except Exception as e:
        logger.debug(f"Erreur lors de la récupération du champ {field_name} : {str(e)}")
    
    logger.info(f"Création du champ personnalisé : {field_name}")
    
    field_data = {
        'name': field_name,
        'label': field_name.replace('_', ' ').title(),
        'type': field_type,
        'description': field_description,
        'content_types': content_types,
        'required': False,
        'default': None
    }
    
    return nb.extras.custom_fields.create(**field_data)

def get_or_create_tag(nb, tag_name, tag_slug, tag_description):
    """Obtient ou crée un tag dans Netbox"""
    try:
        tag = nb.extras.tags.get(slug=tag_slug)
        if tag:
            logger.info(f"Tag existant : {tag_slug}")
            return tag
    except Exception as e:
        logger.debug(f"Erreur lors de la récupération du tag {tag_slug} : {str(e)}")
    
    logger.info(f"Création du tag : {tag_slug}")
    return nb.extras.tags.create(
        name=tag_name,
        slug=tag_slug,
        description=tag_description
    )

def process_subscription_data(nb, subscription_data, config, azure_tag):
    """Traite les données d'un abonnement"""
    logger.info(f"Traitement de l'abonnement : {subscription_data['subscription_name']}")
    
    # Logique de traitement simplifiée pour l'exemple
    # (reprendre la logique complète du script original)
    
    for vnet in subscription_data['vnets']:
        logger.info(f"Traitement du VNet : {vnet['name']}")
        # Traitement des VNets et sous-réseaux...

def parse_arguments():
    """Parse les arguments de ligne de commande"""
    parser = argparse.ArgumentParser(description='Sync Azure vers Netbox avec configuration YAML')
    parser.add_argument('--config', '-c', help='Fichier de configuration YAML', 
                       default='config.yaml')
    parser.add_argument('--netbox-url', help='URL Netbox (override config)')
    parser.add_argument('--netbox-token', help='Token API Netbox (override config)')
    parser.add_argument('--interactive', action='store_true', 
                       help='Authentification interactive Azure (override config)')
    return parser.parse_args()

def main():
    """Fonction principale"""
    args = parse_arguments()
    
    # Chargement de la configuration
    config = AzureNetboxConfig(args.config)
    
    # Override avec les arguments CLI si fournis
    if args.netbox_url:
        config.config['netbox']['url'] = args.netbox_url
    if args.netbox_token:
        config.config['netbox']['token'] = args.netbox_token
    if args.interactive:
        config.config['azure']['authentication']['method'] = 'interactive'
    
    # Validation des paramètres Netbox
    netbox_config = config.get_netbox_config()
    if not netbox_config['url'] or not netbox_config['token']:
        logger.error("URL et token Netbox requis")
        sys.exit(1)
    
    try:
        logger.info("Démarrage de la synchronisation Azure vers Netbox")
        
        # Obtention des credentials Azure
        credential = get_azure_credentials(config)
        
        # Obtention des abonnements à traiter
        subscriptions = get_subscriptions_to_process(credential, config)
        
        if not subscriptions:
            logger.error("Aucun abonnement trouvé")
            sys.exit(1)
        
        all_network_data = []
        
        # Traitement de chaque abonnement
        for subscription in subscriptions:
            subscription_id = subscription.subscription_id
            subscription_data = {
                'subscription_id': subscription_id,
                'subscription_name': subscription.display_name,
                'vnets': []
            }
            
            # Obtention des VNets et sous-réseaux
            vnets_data = get_vnets_and_subnets(subscription_id, credential, config)
            
            # Ici vous ajouteriez la logique pour obtenir les périphériques
            # vnets_with_devices = get_devices_in_subnet(subscription_id, credential, vnets_data)
            
            subscription_data['vnets'] = vnets_data
            all_network_data.append(subscription_data)
        
        # Synchronisation vers Netbox
        sync_to_netbox(all_network_data, config)
        
        logger.info("Synchronisation terminée avec succès")
        
    except Exception as e:
        logger.error(f"Erreur pendant la synchronisation : {str(e)}", exc_info=True)
        sys.exit(1)

if __name__ == "__main__":
    main()
