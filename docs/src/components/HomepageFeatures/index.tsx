import type {ReactNode} from 'react';
import clsx from 'clsx';
import Heading from '@theme/Heading';
import styles from './styles.module.css';

type FeatureItem = {
  title: string;
  emoji: string;
  description: ReactNode;
};

const FeatureList: FeatureItem[] = [
  {
    title: 'Tek bakışta',
    emoji: '🟢',
    description: (
      <>
        Tüm AI servislerinizin durumu menü çubuğunda renkli noktalarla:
        yeşil bol, amber azalıyor, kırmızı limite yakın.
      </>
    ),
  },
  {
    title: 'Canlı limitler ve geri sayım',
    emoji: '⏱️',
    description: (
      <>
        Claude seans limitleri, Codex kotaları ve Antigravity grup kotaları
        gerçek zamanlı — her limitin ne zaman sıfırlanacağıyla birlikte.
      </>
    ),
  },
  {
    title: 'Gizlilik odaklı',
    emoji: '🔒',
    description: (
      <>
        Yalnızca yerel uygulama ayarlarını ve macOS Keychain'i okur.
        Hiçbir veri makinenizden çıkmaz.
      </>
    ),
  },
];

function Feature({title, emoji, description}: FeatureItem) {
  return (
    <div className={clsx('col col--4')}>
      <div className="text--center">
        <div className={styles.featureEmoji} role="img">
          {emoji}
        </div>
      </div>
      <div className="text--center padding-horiz--md">
        <Heading as="h3">{title}</Heading>
        <p>{description}</p>
      </div>
    </div>
  );
}

export default function HomepageFeatures(): ReactNode {
  return (
    <section className={styles.features}>
      <div className="container">
        <div className="row">
          {FeatureList.map((props, idx) => (
            <Feature key={idx} {...props} />
          ))}
        </div>
      </div>
    </section>
  );
}
