"""
Redis configuration
"""

from redis import Redis

from api.settings import settings

redis_store = Redis.from_url(f"redis://{settings.REDIS_HOST}:{settings.REDIS_PORT}/0")
